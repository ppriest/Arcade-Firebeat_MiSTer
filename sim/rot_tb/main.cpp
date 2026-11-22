// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_rot16 against MAME's screens (scripts/mame_kbm_screens.py), rotated here:
//
//   scripts/run_verilator.sh rot_tb +kbm=debug/kbm-screens4000 +mode=0|1|2 [+stall=N] [+ll] [+cw]
//   scripts/run_verilator.sh rot_tb -GBANKS=2 -GCDC=1 +bm3=debug/bm3-vram3200 [+stall=N] [+cw]
//
// +bm3: MAME's 640 x 480 frame (screen_in.bin) at 800 x 525, the video on clk_v (100.7 MHz, a pixel
// every fourth clock) through fb_pix_cdc to the rotator on clk (66.667 MHz), the edges interleaved
// by time.
//
// +mode: the left screen, the right, or both stacked as fb_gcu_disp shows them, at its timing. The
// framebuffer the rotator offers after the sixth frame must be the source rotated 90 degrees
// counter-clockwise (+cw: clockwise), every pixel. +stall=N: each write command (a burst) waits a uniform 0..N clocks
// before its first beat, the rest following a beat a clock (the port's share
// of VRAM traffic); a slice lost to that shows in late.
#include "Vtb_rot.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string kbm, bm3;
    int mode = 2, stall = 0;
    bool ll = false, cw = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "+cw") cw = true;
        if (a.rfind("+kbm=", 0) == 0) kbm = a.substr(5);
        if (a.rfind("+bm3=", 0) == 0) bm3 = a.substr(5);
        if (a.rfind("+mode=", 0) == 0) mode = atoi(a.c_str() + 6);
        if (a.rfind("+stall=", 0) == 0) stall = atoi(a.c_str() + 7);
        if (a == "+ll") ll = true;
    }
    const bool B = !bm3.empty();
    const int W = B ? 640 : 512, H1 = B ? 480 : 384, HT = B ? 800 : 687, VT1 = B ? 525 : 416;
    if (B) mode = 0;
    int H = mode == 2 ? 2 * H1 : H1, VT = mode == 2 ? 2 * VT1 : VT1, div = mode == 2 ? 2 : 4;
    std::vector<uint32_t> src((size_t)W * H);
    if (B) {
        FILE *fp = fopen((bm3 + "/screen_in.bin").c_str(), "rb");
        if (!fp || fread(src.data(), 4, src.size(), fp) != src.size()) { fprintf(stderr, "cannot read %s/screen_in.bin\n", bm3.c_str()); return 1; }
        fclose(fp);
    }
    for (int k = 0; k < (B ? 0 : mode == 2 ? 2 : 1); k++) {
        std::string f = kbm + "/screen_" + std::to_string(mode == 2 ? k : mode) + ".bin";
        FILE *fp = fopen(f.c_str(), "rb");
        if (!fp || fread(src.data() + (size_t)k * W * H1, 4, (size_t)W * H1, fp) != (size_t)W * H1) {
            fprintf(stderr, "cannot read %s\n", f.c_str());
            return 1;
        }
        fclose(fp);
    }

    auto *t = new Vtb_rot;
    std::vector<uint64_t> mem(3u << 20, 0);       // 8 MB x 3
    std::mt19937 rnd(1);
    t->enable = 1; t->cw = cw; t->reset = 1; t->FB_LL = ll; t->FB_VBL = 0; t->m_waitn = 1; t->ce_pix = 0; t->de = 0; t->vs = 0;
    double tc = 0, tv = 0;
    const double PC = 15.0, PV = 1000.0 / 100.7;
    auto vtick = [&]() { t->clk_v = 0; t->eval(); t->clk_v = 1; t->eval(); tv += PV; };
    auto tick = [&]() {
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        tc += PC;
    };
    for (int i = 0; i < 8; i++) tick();
    t->reset = 0;

    long writes = 0, wait = 0, bad_addr = 0;
    uint32_t b_base = 0;                           // the burst being taken: its address, beats left, next beat
    int b_left = 0, b_k = 0;
    bool on = false;
    uint32_t show_base = 0;
    for (int frame = 0; frame < 7; frame++) {
        for (int v = 0; v < VT; v++) for (int h = 0; h < HT; h++) for (int d = 0; d < div; d++) {
            bool de = h < W && v < H;
            t->ce_pix = d == div - 1;
            t->de = de;
            t->vs = v >= H + 2 && v < H + 4;
            uint32_t p = de ? src[(size_t)v * W + h] : 0;
            t->r = p >> 16; t->g = p >> 8; t->b = p;
            // the scaler's vblank, one line each frame while the source is in its own
            t->FB_VBL = v == H + 8;
            if (t->m_write) {
                if (wait > 0 && b_left == 0) { t->m_waitn = 0; wait--; }
                else t->m_waitn = 1;
            } else t->m_waitn = 1;
            // CDC: this pixel clock's edge, after the rotator's edges due before it
            while (t->cdc_on && tc <= tv) {
                t->eval();
                bool take = t->m_write && t->m_waitn;
                uint32_t a = t->m_addr, lo = t->m_wdata, hi = t->m_wdata_hi;
                const int burst = t->m_burst;
                tick();
                if (take) {
                    if (b_left == 0) { b_base = a; b_left = burst / 2; b_k = 0; writes++; }
                    uint32_t o = b_base + 8u * b_k - 0x24000000u;
                    if ((b_base & 7) || (o >> 3) >= mem.size()) bad_addr++;
                    else mem[o >> 3] = (uint64_t)hi << 32 | lo;
                    b_k++;
                    if (--b_left == 0) wait = stall ? rnd() % (stall + 1) : 0;
                }
                if (t->m_write) t->m_waitn = (wait > 0 && b_left == 0) ? (wait--, 0) : 1;
                else t->m_waitn = 1;
            }
            if (t->cdc_on) { vtick(); continue; }
            t->eval();
            bool take = t->m_write && t->m_waitn;
            uint32_t a = t->m_addr, lo = t->m_wdata, hi = t->m_wdata_hi;
            const int burst = t->m_burst;
            tick();
            if (take) {
                if (b_left == 0) { b_base = a; b_left = burst / 2; b_k = 0; writes++; }
                uint32_t o = b_base + 8u * b_k - 0x24000000u;
                if ((b_base & 7) || (o >> 3) >= mem.size()) bad_addr++;
                else mem[o >> 3] = (uint64_t)hi << 32 | lo;
                b_k++;
                if (--b_left == 0) wait = stall ? rnd() % (stall + 1) : 0;
            }
        }
    }
    t->ce_pix = 0;
    on = t->FB_EN;
    show_base = t->FB_BASE;
    int fw = t->FB_WIDTH, fh = t->FB_HEIGHT, stride = t->FB_STRIDE, fmt = t->FB_FORMAT;
    long bad = 0, seen = 0;
    uint32_t o = show_base - 0x24000000u;
    const uint16_t *fb = (const uint16_t *)mem.data();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        uint32_t s = src[(size_t)y * W + x];
        uint16_t want = ((s >> 19) & 31) | ((s >> 11) & 31) << 5 | ((s >> 3) & 31) << 10;
        int row = cw ? x : W - 1 - x, col = cw ? H - 1 - y : y;
        uint16_t got = fb[(o + (size_t)row * stride + 2 * (size_t)col) / 2];
        seen++;
        if (got != want && bad++ < 8)
            fprintf(stderr, "  source %d,%d (fb %d,%d): %04X, want %04X\n", x, y, col, row, got, want);
    }
    printf("mode %d%s stall %d: FB_EN %d, %dx%d stride %d format %02X, base %08X; %ld writes, %ld bad addresses; "
           "%ld pixels, %ld differ; late %u\n", mode, cw ? " cw" : "", stall, on, fw, fh, stride, fmt, show_base, writes, bad_addr, seen, bad, t->late);
    bool ok = on && fw == H && fh == W && bad == 0 && bad_addr == 0 && t->late == 0;
    delete t;
    return ok ? 0 : 1;
}
