// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_gcu_disp against MAME's composed screen (scripts/mame_vram_window.py), or a synthetic case
// from scripts/disp_random.py:
//
//   scripts/run_verilator.sh disp_tb +win=debug/ppp11-vram21400 [+end=out] [+lat=20] [+busy=10] [+gap=0]
//   scripts/run_verilator.sh disp_tb +vram=<raw> +regs=<regs.txt> +screen=<bin>
//   scripts/run_verilator.sh disp_tb -GKBM=1 +kbm=debug/kbm-screens4000 +mode=0|1|2 [+flip=1]
//
// +flip=1: the picture turned 180 degrees, compared with MAME's turned 180 degrees here.
// +kbm: Keyboardmania's two GCUs (scripts/mame_kbm_screens.py). +mode: the first GCU's screen, the
// second's, or both stacked, each compared with its MAME screen.
// VRAM is the window's vram_<end>.raw, the registers its regs_<end>.txt; the third frame out is
// compared with screen_<end>.bin (0xFFRRGGBB, MAME's 5 to 8 bit expansion), every visible pixel.
// The first 10 differing pixels are printed, every one with ALLDIFF set in the environment.
// -GVCLK=1 (bm3): scan-out on clk_v, 100.7 MHz against clk's 66.667, the two clocks' edges
// interleaved by time; the frame's length is reported in ns. A CRTC register's half the file has as 0
// was never written, and device_reset's stands: the file has no masks (bm3 writes 0x08's low half
// alone, which k057714.cpp ignores and fb_gcu_shell merges).

#include "Vtb_disp.h"
#include "verilated.h"
#include "../common/ddr3_model.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static Vtb_disp *t;
static Ddr3Model ddr;
static uint64_t clocks = 0;                 // the scan-out clock's
static double tc = 0, tv = 0;               // the next edge of clk, clk_v, in ns
static const double PC = 15.0, PV = 1000.0 / 100.7;

// one edge of whichever clock is next; true when it was the scan-out clock's
static bool tick() {
    if (!t->vclk_on || tc <= tv) {
        ddr.sample(t);
        t->clk = 1; t->eval();
        ddr.drive(t);
        t->clk = 0; t->eval();
        tc += PC;
        if (!t->vclk_on) { clocks++; return true; }
        return false;
    }
    t->clk_v = 1; t->eval();
    t->clk_v = 0; t->eval();
    tv += PV;
    clocks++;
    return true;
}

static void frame_edge() {
    int vs = t->vid_vs;
    while (!(t->vid_vs && !vs)) { vs = t->vid_vs; tick(); }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string win, end = "in", vram, regs, screen, kbm;
    int test = 0, mode = 0, flip = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("+win=", 0) == 0) win = a.substr(5);
        else if (a.rfind("+end=", 0) == 0) end = a.substr(5);
        else if (a.rfind("+vram=", 0) == 0) vram = a.substr(6);
        else if (a.rfind("+regs=", 0) == 0) regs = a.substr(6);
        else if (a.rfind("+screen=", 0) == 0) screen = a.substr(8);
        else if (a.rfind("+kbm=", 0) == 0) kbm = a.substr(5);
        else if (a.rfind("+mode=", 0) == 0) mode = atoi(a.c_str() + 6);
        else if (a.rfind("+flip=", 0) == 0) flip = atoi(a.c_str() + 6);
        else if (a.rfind("+lat=", 0) == 0) ddr.lat = atoi(a.c_str() + 5);
        else if (a.rfind("+busy=", 0) == 0) ddr.busy = atoi(a.c_str() + 6);
        else if (a.rfind("+gap=", 0) == 0) ddr.gap = atoi(a.c_str() + 5);
    }
    if (!win.empty()) {
        if (vram.empty()) vram = win + "/vram_" + end + ".raw";
        if (regs.empty()) regs = win + "/regs_" + end + ".txt";
        if (screen.empty()) screen = win + "/screen_" + end + ".bin";
    }

    if (!kbm.empty()) {
        vram = kbm + "/vram_0.raw";
        regs = kbm + "/regs_0.txt";
        screen = kbm + "/screen_" + (mode == 1 ? "1" : "0") + ".bin";
    }

    std::vector<uint32_t> vin(0x800000);
    FILE *f = fopen(vram.c_str(), "rb");
    if (!f || fread(vin.data(), 4, vin.size(), f) != vin.size()) { fprintf(stderr, "cannot read %s\n", vram.c_str()); return 1; }
    fclose(f);
    for (uint32_t i = 0; i < Ddr3Model::BEATS; i++) ddr.mem[i] = (uint64_t)vin[2 * i + 1] << 32 | vin[2 * i];

    if (!kbm.empty()) {
        std::vector<uint32_t> v2(0x800000);
        f = fopen((kbm + "/vram_1.raw").c_str(), "rb");
        if (!f || fread(v2.data(), 4, v2.size(), f) != v2.size()) { fprintf(stderr, "no vram_1.raw\n"); return 1; }
        fclose(f);
        for (uint32_t i = 0; i < Ddr3Model::BEATS; i++) ddr.mem2[i] = (uint64_t)v2[2 * i + 1] << 32 | v2[2 * i];
    }

    t = new Vtb_disp;
    t->screen = mode;
    if (!kbm.empty()) {
        uint32_t rb[64] = {0};
        rb[0] = 0x027F0F2F; rb[1] = 0x01DF0920; rb[2] = 0x5F010000;
        FILE *fb = fopen((kbm + "/regs_1.txt").c_str(), "r");
        if (!fb) { fprintf(stderr, "no regs_1.txt\n"); return 1; }
        unsigned ab, vb;
        while (fscanf(fb, "%x %x", &ab, &vb) == 2) if (ab < 0x100) rb[ab / 4] = vb;
        fclose(fb);
        for (int k = 0; k < 3; k++) t->b_crtc[k] = rb[k];
        t->b_layer = rb[0x10 / 4] & 0xFFFF;
        uint64_t al = 0, x = 0, y = 0, w = 0, h = 0;
        for (int k = 0; k < 4; k++) {
            uint64_t aw = (rb[0x14 / 4 + k / 2] >> (k & 1 ? 0 : 16)) & 0xFFFF;
            al |= aw << 16 * k;
            x |= (uint64_t)(rb[0x20 / 4 + k] & 0xFFFF) << 16 * k;
            y |= (uint64_t)(rb[0x20 / 4 + k] >> 16) << 16 * k;
            w |= (uint64_t)(rb[0x30 / 4 + k] & 0xFFFF) << 16 * k;
            h |= (uint64_t)(rb[0x30 / 4 + k] >> 16) << 16 * k;
            t->b_base[k] = rb[0x40 / 4 + k];
        }
        t->b_alpha = al; t->b_x = x; t->b_y = y; t->b_w = w; t->b_h = h;
        t->b_6c = rb[0x6C / 4] & 0xFFFF;
    }
    // device_reset's CRTC, then the file's registers
    uint32_t rf[64] = {0};
    rf[0] = 0x027F0F2F; rf[1] = 0x01DF0920; rf[2] = 0x5F010000;
    for (int k = 0; k < 4; k++) rf[0x14 / 4 + k / 2] |= 0x0840u << (k & 1 ? 0 : 16);
    f = fopen(regs.c_str(), "r");
    if (!f) { fprintf(stderr, "no %s\n", regs.c_str()); return 1; }
    unsigned a, v;
    while (fscanf(f, "%x %x", &a, &v) == 2) if (a < 0x0C) {
        if (v >> 16) rf[a / 4] = (rf[a / 4] & 0xFFFF) | (v & 0xFFFF0000);
        if (v & 0xFFFF) rf[a / 4] = (rf[a / 4] & 0xFFFF0000) | (v & 0xFFFF);
    } else if (a < 0x100) rf[a / 4] = v;
    fclose(f);
    for (int k = 0; k < 3; k++) t->crtc[k] = rf[k];
    t->layer = rf[0x10 / 4] & 0xFFFF;
    uint64_t al = 0, x = 0, y = 0, w = 0, h = 0;
    for (int k = 0; k < 4; k++) {
        uint64_t aw = (rf[0x14 / 4 + k / 2] >> (k & 1 ? 0 : 16)) & 0xFFFF;
        al |= aw << 16 * k;
        x |= (uint64_t)(rf[0x20 / 4 + k] & 0xFFFF) << 16 * k;
        y |= (uint64_t)(rf[0x20 / 4 + k] >> 16) << 16 * k;
        w |= (uint64_t)(rf[0x30 / 4 + k] & 0xFFFF) << 16 * k;
        h |= (uint64_t)(rf[0x30 / 4 + k] >> 16) << 16 * k;
        t->fr_base[k] = rf[0x40 / 4 + k];
    }
    t->fr_alpha = al; t->fr_x = x; t->fr_y = y; t->fr_w = w; t->fr_h = h;
    t->reg_6c = rf[0x6C / 4] & 0xFFFF;
    t->test = test;
    t->flip = flip;

    int hv = (rf[0] >> 16) + 1, vv = (rf[1] >> 16) + 1;
    std::vector<uint32_t> ref((size_t)hv * vv);
    f = fopen(screen.c_str(), "rb");
    if (!f || fread(ref.data(), 4, ref.size(), f) != ref.size()) { fprintf(stderr, "cannot read %s (%dx%d)\n", screen.c_str(), hv, vv); return 1; }
    fclose(f);
    if (mode == 2) {
        ref.resize((size_t)hv * vv * 2);
        f = fopen((kbm + "/screen_1.bin").c_str(), "rb");
        if (!f || fread(ref.data() + (size_t)hv * vv, 4, (size_t)hv * vv, f) != (size_t)hv * vv) { fprintf(stderr, "no screen_1.bin\n"); return 1; }
        fclose(f);
        vv *= 2;
    }

    t->reset = 1;
    for (int i = 0; i < 24; i++) tick();
    t->reset = 0;
    // the first frame has the reset's timing; the second is built from the registers
    frame_edge(); frame_edge(); frame_edge();

    uint64_t c0 = clocks;
    double ns0 = t->vclk_on ? tv : tc;
    int px = 0, py = -1, prev_de = 0, bad = 0, seen = 0, vs = 1;
    while (true) {
        if (!tick()) continue;
        if (t->vid_vs && !vs) break;
        vs = t->vid_vs;
        if (!t->ce_pix) continue;
        int de = !(t->vid_hb || t->vid_vb);
        if (de && !prev_de) { px = 0; py++; }
        if (de) {
            uint32_t got = (uint32_t)t->vid_r << 16 | t->vid_g << 8 | t->vid_b;
            uint32_t exp = (px < hv && py < vv) ? ref[flip ? (size_t)(vv - 1 - py) * hv + (hv - 1 - px) : (size_t)py * hv + px] & 0xFFFFFF : 0xFFFFFFFF;
            if (got != exp) {
                if (bad < 10 || getenv("ALLDIFF")) fprintf(stderr, "  pixel %d,%d: %06X, MAME %06X\n", px, py, got, exp);
                bad++;
            }
            seen++;
            px++;
        }
        prev_de = de;
    }
    double fns = (t->vclk_on ? tv : tc) - ns0;
    printf("%dx%d, frame %llu clocks (%.0f ns, %.3f Hz), %d pixels checked, %d differ; late lines %u; lat %d busy %d%%\n",
           hv, vv, (unsigned long long)(clocks - c0), fns, 1e9 / fns, seen, bad, t->late, ddr.lat, ddr.busy);
    bool ok = bad == 0 && seen == hv * vv && t->late == 0;
    delete t;
    return ok ? 0 : 1;
}
