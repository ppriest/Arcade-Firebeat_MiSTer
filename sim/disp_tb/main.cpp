// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_gcu_disp against MAME's composed screen (scripts/mame_vram_window.py), or a synthetic case
// from scripts/disp_random.py:
//
//   scripts/run_verilator.sh disp_tb +win=debug/ppp11-vram21400 [+end=out] [+lat=20] [+busy=10] [+gap=0]
//   scripts/run_verilator.sh disp_tb +vram=<raw> +regs=<regs.txt> +screen=<bin>
//
// VRAM is the window's vram_<end>.raw, the registers its regs_<end>.txt; the third frame out is
// compared with screen_<end>.bin (0xFFRRGGBB, MAME's 5 to 8 bit expansion), every visible pixel.
// The first 10 differing pixels are printed, every one with ALLDIFF set in the environment.

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
static uint64_t clocks = 0;

static void tick() {
    ddr.sample(t);
    t->clk = 1; t->eval();
    ddr.drive(t);
    t->clk = 0; t->eval();
    clocks++;
}

static void frame_edge() {
    int vs = t->vid_vs;
    while (!(t->vid_vs && !vs)) { vs = t->vid_vs; tick(); }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string win, end = "in", vram, regs, screen;
    int test = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("+win=", 0) == 0) win = a.substr(5);
        else if (a.rfind("+end=", 0) == 0) end = a.substr(5);
        else if (a.rfind("+vram=", 0) == 0) vram = a.substr(6);
        else if (a.rfind("+regs=", 0) == 0) regs = a.substr(6);
        else if (a.rfind("+screen=", 0) == 0) screen = a.substr(8);
        else if (a.rfind("+lat=", 0) == 0) ddr.lat = atoi(a.c_str() + 5);
        else if (a.rfind("+busy=", 0) == 0) ddr.busy = atoi(a.c_str() + 6);
        else if (a.rfind("+gap=", 0) == 0) ddr.gap = atoi(a.c_str() + 5);
    }
    if (!win.empty()) {
        if (vram.empty()) vram = win + "/vram_" + end + ".raw";
        if (regs.empty()) regs = win + "/regs_" + end + ".txt";
        if (screen.empty()) screen = win + "/screen_" + end + ".bin";
    }

    std::vector<uint32_t> vin(0x800000);
    FILE *f = fopen(vram.c_str(), "rb");
    if (!f || fread(vin.data(), 4, vin.size(), f) != vin.size()) { fprintf(stderr, "cannot read %s\n", vram.c_str()); return 1; }
    fclose(f);
    for (uint32_t i = 0; i < Ddr3Model::BEATS; i++) ddr.mem[i] = (uint64_t)vin[2 * i + 1] << 32 | vin[2 * i];

    t = new Vtb_disp;
    // device_reset's CRTC, then the file's registers
    uint32_t rf[64] = {0};
    rf[0] = 0x027F0F2F; rf[1] = 0x01DF0920; rf[2] = 0x5F010000;
    for (int k = 0; k < 4; k++) rf[0x14 / 4 + k / 2] |= 0x0840u << (k & 1 ? 0 : 16);
    f = fopen(regs.c_str(), "r");
    if (!f) { fprintf(stderr, "no %s\n", regs.c_str()); return 1; }
    unsigned a, v;
    while (fscanf(f, "%x %x", &a, &v) == 2) if (a < 0x100) rf[a / 4] = v;
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

    int hv = (rf[0] >> 16) + 1, vv = (rf[1] >> 16) + 1;
    std::vector<uint32_t> ref((size_t)hv * vv);
    f = fopen(screen.c_str(), "rb");
    if (!f || fread(ref.data(), 4, ref.size(), f) != ref.size()) { fprintf(stderr, "cannot read %s (%dx%d)\n", screen.c_str(), hv, vv); return 1; }
    fclose(f);

    t->reset = 1;
    for (int i = 0; i < 8; i++) tick();
    t->reset = 0;
    // the first frame has the reset's timing; the second is built from the registers
    frame_edge(); frame_edge(); frame_edge();

    uint64_t c0 = clocks;
    int px = 0, py = -1, prev_de = 0, bad = 0, seen = 0, vs = 1;
    while (true) {
        tick();
        if (t->vid_vs && !vs) break;
        vs = t->vid_vs;
        if (!t->ce_pix) continue;
        int de = !(t->vid_hb || t->vid_vb);
        if (de && !prev_de) { px = 0; py++; }
        if (de) {
            uint32_t got = (uint32_t)t->vid_r << 16 | t->vid_g << 8 | t->vid_b;
            uint32_t exp = (px < hv && py < vv) ? ref[(size_t)py * hv + px] & 0xFFFFFF : 0xFFFFFFFF;
            if (got != exp) {
                if (bad < 10 || getenv("ALLDIFF")) fprintf(stderr, "  pixel %d,%d: %06X, MAME %06X\n", px, py, got, exp);
                bad++;
            }
            seen++;
            px++;
        }
        prev_de = de;
    }
    printf("%dx%d, frame %llu clocks, %d pixels checked, %d differ; late lines %u; lat %d busy %d%%\n",
           hv, vv, (unsigned long long)(clocks - c0), seen, bad, t->late, ddr.lat, ddr.busy);
    bool ok = bad == 0 && seen == hv * vv && t->late == 0;
    delete t;
    return ok ? 0 : 1;
}
