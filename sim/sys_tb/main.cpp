// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/firebeat_sys.sv as the board's top level will drive it (sim/sys_tb/tb_sys.sv has the
// memory models), with clk at 66.667 MHz and clk_mem at 133.333 MHz:
//
// The board is held in reset (hold) through steps 1-5: they check the memories, the transfers and
// the picture around it.
//
//   1. the .mra's image (index 0: a random 512 KB "BIOS" and a 200-byte dongle) and the NVRAM
//      file (index 4: three flash chips and the RTC's 4,152 bytes) downloaded as hps_io sends
//      them, 16 bits a write, waiting on ioctl_wait;
//   2. read-back passes over the BIOS and the flash on the cache port against the files;
//   3. the NVRAM file uploaded as hps_io reads it, against the file (the RTC's A and B as
//      fb_rtc65271 keeps them, its version byte 0);
//   4. the test picture through DDR3 and scan-out: frame length, every visible pixel of a frame
//      against the pattern, no late line; then the inverted picture;
//   5. the HPS's reset (emu RESET) mid-frame, with scan-out reads in flight, which the DDR3 bridge
//      drops: the plain picture comes back, written again, with no late line after.
//
//   6. with +boot=DIR (sim/boot_tb's: DIR/nvram_start, DIR/dongle.bin) and +bios=FILE: the real
//      image and NVRAM file downloaded, the board released for +frames=N frames (default 100),
//      its PC printed every 10; a model meeting a mode it does not run fails. Then the NVRAM file
//      is uploaded with the board running (its CPU paused) and the flash part compared.
//
//     scripts/run_verilator.sh sys_tb [+seed=N] [+lat=N] [+busy=P] [+flash=BYTES]
//         [+boot=DIR +bios=FILE [+frames=N] [+shot=FILE]]
//
// +shot: after step 6's frames, the next frame's visible pixels as a binary PPM.
// +io=FILE: step 6's device accesses (fb_board's bus monitor), one "R|W addr mask data" a line.
//
// +flash: how much of the flash images to send and check (default all 6 MB); the RTC's part of
// the file is always sent at its offset, 0x600000.

#include "Vtb_sys.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <random>
#include <string>
#include <algorithm>

static const size_t NV_SIZE = 0x600000 + 4152;   // the NVRAM file

double sc_time_stamp() { return 0; }

static Vtb_sys *t;
static uint64_t clocks = 0;
static int errors = 0;

static FILE *iolog;                     // +io: step 6's device accesses, as MAME's io.txt

static void tick() {
    if (iolog && t->mon_v)
        fprintf(iolog, "%c %08X %08X %08X\n", t->mon_we ? 'W' : 'R', (unsigned)t->mon_addr, t->mon_mask, t->mon_data);
    if (iolog && t->dcr_v)              // "D dcr data busy": a DMA register write, the engine busy or not
        fprintf(iolog, "D %03X %08X %d\n", t->dcr_a, t->dcr_d, t->dma_e_busy);
    t->clk = 1; t->clk_mem = 1; t->eval();
    t->clk_mem = 0; t->eval();
    t->clk = 0; t->clk_mem = 1; t->eval();
    t->clk_mem = 0; t->eval();
    clocks++;
}

static void fail(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    if (errors < 20) { vprintf(fmt, ap); printf("\n"); }
    va_end(ap);
    errors++;
}

// hps_io's download: a write a halfword, the next after ioctl_wait drops and a few clocks more
static void download(int index, const std::vector<uint8_t> &f, size_t skip_from = 0, size_t skip_to = 0) {
    t->ioctl_index = index; t->ioctl_download = 1;
    tick();
    for (size_t a = 0; a < f.size(); a += 2) {
        if (a >= skip_from && a < skip_to) continue;
        t->ioctl_addr = a;
        t->ioctl_dout = f[a] | (a + 1 < f.size() ? f[a + 1] << 8 : 0);
        t->ioctl_wr = 1; tick(); t->ioctl_wr = 0;
        for (int k = 0; k < 3; k++) tick();
        int n = 0;
        while (t->ioctl_wait) { tick(); if (++n > 10000) { fail("download: ioctl_wait stuck at %zx", a); return; } }
    }
    t->ioctl_download = 0;
    tick();
}

// hps_io's upload: ioctl_rd for an address, the data taken at the next transfer once ioctl_wait
// is low, then the address advanced and ioctl_rd again
static std::vector<uint8_t> upload(int index, size_t size, size_t skip_from = 0, size_t skip_to = 0) {
    std::vector<uint8_t> out(size, 0);
    t->ioctl_index = index; t->ioctl_upload = 1;
    size_t a = 0;
    t->ioctl_addr = 0; t->ioctl_rd = 1; tick(); t->ioctl_rd = 0;
    while (a < size) {
        for (int k = 0; k < 3; k++) tick();
        int n = 0;
        while (t->ioctl_wait) { tick(); if (++n > 10000) { fail("upload: ioctl_wait stuck at %zx", a); return out; } }
        out[a] = t->ioctl_din & 0xFF;
        if (a + 1 < size) out[a + 1] = t->ioctl_din >> 8;
        a += 2;
        if (a >= skip_from && a < skip_to) a = skip_to;
        t->ioctl_addr = a; t->ioctl_rd = 1; tick(); t->ioctl_rd = 0;
    }
    t->ioctl_upload = 0;
    tick();
    return out;
}

static std::vector<uint8_t> load(const std::string &f) {
    std::vector<uint8_t> v;
    FILE *fp = fopen(f.c_str(), "rb");
    if (!fp) { fail("cannot open %s", f.c_str()); return v; }
    fseek(fp, 0, SEEK_END); v.resize(ftell(fp)); fseek(fp, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), fp) != v.size()) fail("short read %s", f.c_str());
    fclose(fp);
    return v;
}

// a frame: from vsync's rise to the next
static void frame() {
    int vs = t->vid_vs;
    while (!(t->vid_vs && !vs)) { vs = t->vid_vs; tick(); }
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static void check_pass(int sel, const uint8_t *img, size_t bytes, const char *what) {
    t->chk_sel = sel; t->chk_start = 1; tick(); t->chk_start = 0;
    tick();
    while (t->chk_busy) tick();
    tick();
    uint32_t sum = 0;
    for (size_t i = 0; i < bytes; i += 4) sum += be32(img + i);
    printf("  %s: %u lines, sum %08X (expected %08X); fill latency %.2f average, %u worst\n", what,
           t->chk_lines, t->chk_sum, sum, (double)t->chk_lat_sum / t->chk_lines, t->chk_lat_max);
    if (t->chk_sum != sum) fail("%s: sum differs", what);
}

// pattern_writer's picture
static uint16_t pixel(int x, int y, bool inv) {
    uint16_t c;
    if (x == 0 || x == 511 || y == 0 || y == 383 || (x & 63) == 0 || (y & 63) == 0) c = 0x7FFF;
    else if (y < 128) { static const uint16_t bars[8] = {0x7FFF, 0x7FE0, 0x03FF, 0x03E0, 0x7C1F, 0x7C00, 0x001F, 0x0000}; c = bars[x >> 6]; }
    else if (y < 256) c = (x >> 4) << 10 | ((y >> 2) & 31) << 5;
    else c = x >> 4;
    return inv ? (~c & 0x7FFF) : c;
}

// a whole frame from vsync's rise: its length, and every visible pixel against the pattern
static void check_frame(bool inv) {
    int vs = t->vid_vs;
    while (!(t->vid_vs && !vs)) { vs = t->vid_vs; tick(); }
    uint64_t c0 = clocks;
    int x = 0, y = -1, prev_de = 0, bad = 0, seen = 0;
    vs = 1;
    while (true) {
        tick();
        if (t->vid_vs && !vs) break;
        vs = t->vid_vs;
        if (!t->ce_pix) continue;
        // outputs registered at ce_pix: look at them on the next ce
        int de = !(t->vid_hb || t->vid_vb);
        if (de && !prev_de) { x = 0; y++; }
        if (de) {
            uint16_t p = pixel(x, y, inv);
            int r = (p >> 10) & 31, g = (p >> 5) & 31, b = p & 31;
            int er = r << 3 | r >> 2, eg = g << 3 | g >> 2, eb = b << 3 | b >> 2;
            if (t->vid_r != er || t->vid_g != eg || t->vid_b != eb) {
                if (bad < 5) fail("pixel %d,%d: %02X%02X%02X, expected %02X%02X%02X", x, y, t->vid_r, t->vid_g, t->vid_b, er, eg, eb);
                bad++;
            }
            seen++;
            x++;
        }
        prev_de = de;
    }
    // the ce_pix samples above see outputs registered on the previous ce: the frame's last pixel is
    // seen after vsync; the count tells
    printf("  frame (%s): %llu clocks (expected %d), %d visible pixels checked, %d wrong; late lines %u\n",
           inv ? "inverted" : "plain", (unsigned long long)(clocks - c0), 685 * 416 * 4, seen, bad, t->scan_late);
    if (clocks - c0 != 685 * 416 * 4) fail("frame length");
    if (seen != 512 * 384) fail("visible pixels %d", seen);
    if (bad) errors++;
    if (t->scan_late) fail("scan-out late");
}

// a whole frame from vsync's rise, its visible pixels written as a PPM
static void shot(const std::string &f) {
    int vs = t->vid_vs;
    while (!(t->vid_vs && !vs)) { vs = t->vid_vs; tick(); }
    std::vector<std::vector<uint8_t>> rows;
    int prev_de = 0;
    vs = 1;
    while (true) {
        tick();
        if (t->vid_vs && !vs) break;
        vs = t->vid_vs;
        if (!t->ce_pix) continue;
        int de = !(t->vid_hb || t->vid_vb);
        if (de && !prev_de) rows.emplace_back();
        if (de) { rows.back().push_back(t->vid_r); rows.back().push_back(t->vid_g); rows.back().push_back(t->vid_b); }
        prev_de = de;
    }
    size_t w = rows.empty() ? 0 : rows[0].size() / 3;
    FILE *fp = fopen(f.c_str(), "wb");
    if (!fp) { fail("cannot write %s", f.c_str()); return; }
    fprintf(fp, "P6\n%zu %zu\n255\n", w, rows.size());
    for (auto &row : rows) { row.resize(w * 3, 0); fwrite(row.data(), 1, row.size(), fp); }
    fclose(fp);
    printf("  shot: %zu x %zu -> %s\n", w, rows.size(), f.c_str());
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_sys;
    t->test_pic = 1;                    // steps 4-5 show the test picture
    int seed = 1, lat = 20, busy = 10;
    size_t flash = 0x600000;
    std::string boot, bios, shot_file, io_file;
    int frames = 100;
    for (int i = 1; i < argc; i++) {
        sscanf(argv[i], "+seed=%d", &seed);
        sscanf(argv[i], "+lat=%d", &lat);
        sscanf(argv[i], "+busy=%d", &busy);
        if (!strncmp(argv[i], "+flash=", 7)) flash = strtoul(argv[i] + 7, nullptr, 0) & ~15ul;
        if (!strncmp(argv[i], "+boot=", 6)) boot = argv[i] + 6;
        if (!strncmp(argv[i], "+bios=", 6)) bios = argv[i] + 6;
        if (!strncmp(argv[i], "+shot=", 6)) shot_file = argv[i] + 6;
        if (!strncmp(argv[i], "+io=", 4)) io_file = argv[i] + 4;
        sscanf(argv[i], "+frames=%d", &frames);
    }
    std::mt19937 rng(seed);
    t->ddr_lat = lat; t->ddr_busy_pct = busy;

    t->hold = 1;
    t->pll_locked = 0;
    for (int i = 0; i < 20; i++) tick();
    t->pll_locked = 1;
    for (int i = 0; i < 20000; i++) tick();            // the SDRAM's initialisation

    // 1. the image and the NVRAM file
    std::vector<uint8_t> img(0x800C8), nv(NV_SIZE);
    for (auto &b : img) b = rng();
    for (auto &b : nv) b = rng();
    nv[0x600001] = (nv[0x600001] & 0x8F) | 0x20;      // register A: the oscillator on (DV 010)
    uint64_t c0 = clocks;
    download(0, img);
    printf("image: %zu bytes in %llu clocks, %u KB counted\n", img.size(), (unsigned long long)(clocks - c0), t->dl_kb);
    c0 = clocks;
    download(4, nv, flash, 0x600000);
    printf("NVRAM file: flash %zu bytes and the RTC's part in %llu clocks\n", flash, (unsigned long long)(clocks - c0));

    // 2. read-back
    printf("read-back:\n");
    check_pass(0, img.data(), 0x80000, "BIOS");
    if (flash == 0x600000) check_pass(1, nv.data(), 0x600000, "flash");

    // 3. the NVRAM file back
    c0 = clocks;
    std::vector<uint8_t> up = upload(4, nv.size(), flash, 0x600000);
    nv[0x600000] = 0; nv[0x600001] &= 0x70; nv[0x600002] &= 0x87;
    int ub = 0;
    for (size_t a = 0; a < nv.size(); a++) {
        if (a >= flash && a < 0x600000) continue;
        if (up[a] != nv[a]) { if (ub < 5) fail("upload: byte %zx is %02X, expected %02X", a, up[a], nv[a]); ub++; }
    }
    printf("upload: %llu clocks, %d bytes differ\n", (unsigned long long)(clocks - c0), ub);

    // 3b. an RTC never started (DV 000) is not loaded: the RTC keeps what it had
    {
        std::vector<uint8_t> nz(NV_SIZE);
        for (size_t a = 0x600000; a < NV_SIZE; a++) nz[a] = rng();
        nz[0x600001] &= 0x8F;
        download(4, nz, 0, 0x600000);
        std::vector<uint8_t> u2 = upload(4, NV_SIZE, 0, 0x600000);
        int nb = 0;
        for (size_t a = 0x600000; a < NV_SIZE; a++) nb += u2[a] != nv[a];
        if (nb) fail("an RTC with DV 000 was loaded: %d bytes changed", nb);
        printf("RTC with DV 000: %d bytes changed\n", nb);
    }
    // 3c. a short image (a file missing from the .mra) keeps the board in reset; the whole one
    // releases it (read with hold dropped for one evaluation, no clock)
    {
        auto loaded = [&]() { t->hold = 0; t->eval(); bool r = !t->brd_reset; t->hold = 1; t->eval(); return r; };
        std::vector<uint8_t> sh(img.begin(), img.begin() + 0x40000);
        download(0, sh);
        for (int i = 0; i < 100; i++) tick();
        bool short_rel = loaded();
        download(0, img);
        for (int i = 0; i < 100; i++) tick();
        bool whole_rel = loaded();
        if (short_rel) fail("a short image released the board");
        if (!whole_rel) fail("the whole image left the board in reset");
        printf("short image: board %s; whole image: board %s\n", short_rel ? "released" : "held",
               whole_rel ? "released" : "held");
    }

    // 4. the picture: the first, written after reset, then the inverted one
    printf("picture:\n");
    while (!t->pat_done) tick();
    check_frame(false);
    t->pat_variant = 1; t->pat_start = 1; tick(); t->pat_start = 0; t->pat_variant = 0;
    tick(); tick();
    while (!t->pat_done) tick();
    check_frame(true);
    check_frame(true);

    // 5. a frame's line reads in flight across the bridge's reset
    for (int i = 0; i < 200000; i++) tick();
    // a visible line begins and its next line's read goes out with it: reset 30 clocks in, with
    // the DDR3 latency at 20, so the burst's data is still due
    while (!t->vid_hb) tick();
    while (t->vid_hb) tick();
    for (int i = 0; i < 30; i++) tick();
    t->hps_reset = 1;
    for (int i = 0; i < 100; i++) tick();
    t->hps_reset = 0;
    for (int i = 0; i < 10; i++) tick();
    while (!t->pat_done) tick();
    check_frame(false);
    check_frame(false);

    // 6. the board on the real BIOS and NVRAM, through the GCU's display
    t->test_pic = 0;
    if (!boot.empty() && !bios.empty()) {
        printf("board:\n");
        std::vector<uint8_t> im = load(bios), dg = load(boot + "/dongle.bin"), nv2;
        im.resize(0x80000, 0xff);
        im.insert(im.end(), dg.begin(), dg.begin() + std::min<size_t>(dg.size(), 200));
        for (const char *f : {"flash_main", "flash_snd1", "flash_snd2"}) {
            std::vector<uint8_t> v = load(boot + "/nvram_start/" + f);
            v.resize(0x200000, 0xff);
            nv2.insert(nv2.end(), v.begin(), v.end());
        }
        std::vector<uint8_t> rtc = load(boot + "/nvram_start/rtc");
        rtc.resize(4152, 0);
        nv2.insert(nv2.end(), rtc.begin(), rtc.end());
        download(0, im);
        download(4, nv2);
        if (!io_file.empty()) iolog = fopen(io_file.c_str(), "w");
        t->hold = 0;
        for (int i = 0; i < 100; i++) tick();
        if (t->brd_reset) fail("the board is still in reset");
        for (int f = 1; f <= frames && !t->brd_bad; f++) {
            frame();
            if (iolog) fprintf(iolog, "F %d %08X\n", f, t->brd_pc);
            if (f % 10 == 0) printf("  frame %d: PC %08X\n", f, t->brd_pc);
            fflush(stdout);
        }
        if (t->brd_bad) fail("a model met a mode it does not run, PC %08X", t->brd_pc);
        if (iolog) { fclose(iolog); iolog = nullptr; }
        if (!shot_file.empty()) shot(shot_file);
        std::vector<uint8_t> up2 = upload(4, nv2.size());
        int fb = 0, rb = 0;
        for (size_t a = 0; a < 0x600000; a++) fb += up2[a] != nv2[a];
        for (size_t a = 0x600000; a < nv2.size(); a++) rb += up2[a] != nv2[a];
        printf("  upload while running: flash %d bytes differ, RTC part %d (the BIOS may write its registers)\n", fb, rb);
        if (fb) fail("flash differs after upload");
        for (int i = 0; i < 3; i++) { frame(); printf("  after the upload: PC %08X\n", t->brd_pc); }
    }

    printf("%d errors\n%s\n", errors, errors ? "FAIL" : "PASS");
    delete t;
    return errors ? 1 : 0;
}
