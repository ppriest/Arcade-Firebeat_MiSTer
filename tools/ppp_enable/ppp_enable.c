// SPDX-License-Identifier: GPL-3.0-or-later
//
// ppp_enable: switches on Konami's PS2 ParaParaParadise controller (USB 0507:0011) on the MiSTer.
// The controller reports nothing until it gets output report 0x03 with report ID 0
// (Tatsh/pppps2pc: constants.py ENABLE_MAGIC_BYTES, kernel/hid-konami-ppp.c).
//
// The report goes as the kernel driver sends it, a SET_REPORT control request
// (hid_hw_raw_request, HID_OUTPUT_REPORT), through hidraw's HIDIOCSOUTPUT ioctl (Linux 5.11 on).
// Where that ioctl is refused it falls back to write(), which hidraw sends on the interrupt OUT
// endpoint when the device has one.
//
//   ppp_enable          enable every controller attached now, then exit
//   ppp_enable -d       stay running, enabling each controller as it is attached (a node that
//                       reappears, by its inode, is enabled again)

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef HIDIOCSOUTPUT
#define HIDIOCSOUTPUT(len) _IOC(_IOC_WRITE | _IOC_READ, 'H', 0x0B, len)
#endif

#define MAX_NODES 32

struct node {
	char name[32];
	ino_t ino;
};

static int is_ppp(const char *name)
{
	char path[128];
	char line[128];
	int found = 0;

	snprintf(path, sizeof(path), "/sys/class/hidraw/%.16s/device/uevent", name);
	FILE *f = fopen(path, "r");
	if (!f) {
		return 0;
	}
	while (fgets(line, sizeof(line), f)) {
		// bus 0003 (USB), vendor 0507, product 0011
		if (!strncmp(line, "HID_ID=0003:00000507:00000011", 29)) {
			found = 1;
			break;
		}
	}
	fclose(f);
	return found;
}

static int enable(const char *name)
{
	char path[64];
	unsigned char rep[2] = { 0x00, 0x03 };

	snprintf(path, sizeof(path), "/dev/%.16s", name);
	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		printf("ppp_enable: %s: %s\n", path, strerror(errno));
		return -1;
	}

	int r = ioctl(fd, HIDIOCSOUTPUT(sizeof(rep)), rep);
	if (r == (int)sizeof(rep)) {
		printf("ppp_enable: %s enabled (SET_REPORT)\n", path);
		close(fd);
		return 0;
	}
	int err = errno;

	r = (int)write(fd, rep, sizeof(rep));
	if (r == (int)sizeof(rep)) {
		printf("ppp_enable: %s enabled (write; HIDIOCSOUTPUT: %s)\n", path, strerror(err));
		close(fd);
		return 0;
	}
	printf("ppp_enable: %s failed (HIDIOCSOUTPUT: %s, write: %s)\n", path, strerror(err), strerror(errno));
	close(fd);
	return -1;
}

// One pass over /sys/class/hidraw: enables each controller node not in seen[] (by name and inode),
// and leaves seen[] holding the controller nodes enabled so far. Returns how many it enabled;
// *found counts the controller nodes present.
static int scan(struct node *seen, int *nseen, int *found)
{
	struct node now[MAX_NODES];
	int nnow = 0;
	int done = 0;

	*found = 0;
	DIR *d = opendir("/sys/class/hidraw");
	if (!d) {
		*nseen = 0;
		return 0;
	}

	struct dirent *de;
	while ((de = readdir(d)) && nnow < MAX_NODES) {
		if (strncmp(de->d_name, "hidraw", 6) || strlen(de->d_name) > 16) {
			continue;
		}
		if (!is_ppp(de->d_name)) {
			continue;
		}
		(*found)++;

		char path[64];
		struct stat st;
		snprintf(path, sizeof(path), "/dev/%.16s", de->d_name);
		if (stat(path, &st)) {
			continue;
		}

		int old = 0;
		for (int i = 0; i < *nseen; i++) {
			if (!strcmp(seen[i].name, de->d_name) && seen[i].ino == st.st_ino) {
				old = 1;
				break;
			}
		}

		// a node whose enable failed is retried on the next pass
		if (old || enable(de->d_name) == 0) {
			snprintf(now[nnow].name, sizeof(now[nnow].name), "%.16s", de->d_name);
			now[nnow].ino = st.st_ino;
			nnow++;
			if (!old) {
				done++;
			}
		}
	}
	closedir(d);

	memcpy(seen, now, sizeof(now[0]) * nnow);
	*nseen = nnow;
	return done;
}

int main(int argc, char **argv)
{
	struct node seen[MAX_NODES];
	int nseen = 0;
	int found = 0;
	int daemon = argc > 1 && !strcmp(argv[1], "-d");

	setvbuf(stdout, NULL, _IOLBF, 0);

	if (!daemon) {
		int n = scan(seen, &nseen, &found);
		if (found == 0) {
			printf("ppp_enable: no ParaParaParadise controller (0507:0011) attached\n");
		}
		return n > 0 ? 0 : 1;
	}

	for (;;) {
		scan(seen, &nseen, &found);
		sleep(1);
	}
}
