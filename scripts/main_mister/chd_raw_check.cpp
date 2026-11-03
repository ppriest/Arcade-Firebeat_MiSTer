// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host check of Main_MiSTer's support/firebeat (branch firebeat-chd): mount a CD CHD through
// firebeat_mount_hook, read the whole raw image through firebeat_sd_service in 16 KB requests as
// the core does, and compare every byte of its frames with the .bin `chdman extractcd` wrote for
// the same CHD; then print the TOC block that follows them (rtl/board/fb_cd_slot.sv's format).
// A DVD CHD (served as its sectors, no TOC block) is compared with `chdman extractraw` output,
// which may be a range of the disc starting at byte START.
// The SPI, file and core-name functions Main provides on the MiSTer are stubbed here.
//
//     scripts/main_mister/chd_raw_check.sh <file.chd> <file.bin> [START]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "file_io.h"
#include "support/firebeat/firebeat.h"

// ---- stubs for what Main provides ------------------------------------------------------
static uint8_t  captured[16384];
static int      captured_sz = 0;
fileTYPE::fileTYPE() { filp = 0; size = 0; }
fileTYPE::~fileTYPE() {}
int fileTYPE::opened() { return 0; }
int FileClose(fileTYPE *f) { (void)f; return 0; }
const char *getFullPath(const char *name) { return name; }
char *user_io_get_core_name(int) { static char n[] = "Firebeat"; return n; }
int user_io_get_width() { return 1; }
void diskled_on() {}
void EnableIO() {}
void DisableIO() {}
uint16_t fpga_spi(uint16_t w) { return w; }
void spi_block_write(const uint8_t *addr, int, int sz) { memcpy(captured, addr, sz); captured_sz = sz; }
// -----------------------------------------------------------------------------------------

int main(int argc, char **argv)
{
	if (argc != 3 && argc != 4) { fprintf(stderr, "usage: %s file.chd file.bin [start]\n", argv[0]); return 2; }
	long long start = argc == 4 ? atoll(argv[3]) : 0;
	FILE *bin = fopen(argv[2], "rb");
	if (!bin) { perror(argv[2]); return 2; }
	fseek(bin, 0, SEEK_END);
	long long bin_size = ftell(bin);
	fseek(bin, 0, SEEK_SET);

	fileTYPE f;
	int writable = 1;
	if (!firebeat_mount_hook(0, argv[1], &f, &writable)) { fprintf(stderr, "mount refused\n"); return 1; }
	long long data_bytes = ((bin_size + 511) / 512) * 512;
	bool dvd = f.size % 2048 == 0 && f.size != data_bytes + 1024;
	if (dvd) printf("served size %lld: a DVD, compared from byte %lld\n", (long long)f.size, start);
	else printf("served size %lld: .bin %lld, padded %lld, TOC 1024\n", (long long)f.size, bin_size, data_bytes);

	static uint8_t ref[16384];
	long long bad_bytes = 0, first_bad = -1;
	uint64_t blocks = (uint64_t)bin_size / 512;
	for (uint64_t lba = 0; lba < blocks; lba += 32)
	{
		int nblk = (int)((blocks - lba) < 32 ? (blocks - lba) : 32);
		int sz = nblk * 512;
		captured_sz = 0;
		if (firebeat_sd_service(0, 1, lba + start / 512, sz, 0) != 1 || captured_sz != sz) { fprintf(stderr, "service failed at %llu\n", (unsigned long long)lba); return 1; }
		if (fread(ref, 1, sz, bin) != (size_t)sz) { fprintf(stderr, "short .bin read\n"); return 1; }
		for (int i = 0; i < sz; i++)
			if (captured[i] != ref[i]) { if (first_bad < 0) first_bad = (long long)lba * 512 + i; bad_bytes++; }
	}
	if (dvd)
	{
		firebeat_unmount(0);
		printf("compared %llu bytes: %lld differ, first at %lld\n", (unsigned long long)blocks * 512, bad_bytes, first_bad);
		return bad_bytes == 0 ? 0 : 1;
	}
	captured_sz = 0;
	if (firebeat_sd_service(0, 1, (uint64_t)data_bytes / 512, 1024, 0) != 1 || captured_sz != 1024) { fprintf(stderr, "TOC read failed\n"); return 1; }
	printf("TOC: %.4s, %d tracks, version %d\n", (char *)captured, captured[4], captured[5]);
	for (int i = 0; i <= captured[4]; i++)
	{
		uint8_t *e = captured + 8 + 8 * i;
		uint32_t st = e[0] | e[1] << 8 | e[2] << 16 | (uint32_t)e[3] << 24;
		if (i < 3 || i >= captured[4] - 1) printf("  %s %2d: frame %u, %s\n", i == captured[4] ? "lead-out" : "track   ", i + 1, st, e[4] & 1 ? "audio" : "data");
	}
	firebeat_unmount(0);
	printf("compared %llu bytes: %lld differ%s", (unsigned long long)blocks * 512, bad_bytes,
	       first_bad >= 0 ? ", first at " : "\n");
	if (first_bad >= 0) printf("%lld (frame %lld, byte %lld)\n", first_bad, first_bad / 2352, first_bad % 2352);
	return (f.size == data_bytes + 1024 && bad_bytes == 0) ? 0 : 1;
}
