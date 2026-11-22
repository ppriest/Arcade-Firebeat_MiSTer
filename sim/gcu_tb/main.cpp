// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GCU's command engine on a captured window (scripts/mame_vram_window.py), against MAME:
//
//   scripts/run_verilator.sh gcu_tb +win=debug/ppp11-vram21400 [+lat=20] [+busy=10] [+gap=0] [+scan=1|2] [+skip]
//       [+limit=N] [+rst=N] [+prof] [+dump=FILE]
//
// VRAM starts as vram_in.raw (MAME's m_vram words, host order: DDR3 word k is m_vram[k]); the
// register file is loaded from regs_in.txt as scripts/gcu_model.py loads it, then every write of
// gcu_writes.txt goes to the register bus as fast as the GCU takes it. At the end VRAM is compared
// with vram_out.raw, pixel by pixel.
//
// The clocks are the engine's whole time for the window's eight frames (the CPU's time between
// writes is not in the log), against 8 frames of 66.667 MHz at 58.4875 Hz. +scan=1 runs
// fb_gcu_disp on the shell's registers beside the engine; after the VRAM comparison the frame it
// shows is compared with screen_out.bin.
// +scan=2: Keyboardmania's stacked mode instead (both screens from this GCU's registers), its late
// lines counted over the window; no screen comparison.
//
// +rst=N resets the GCU N clocks into the window, mid-command, waits for it to go idle, then
// replays the window from the start on vram_in: the result must still be MAME's, and hornet_ddr3
// must not see a burst cut short.
//
// +prof: the window's clocks by engine state (S_WAIT by the state it returns to), and how many of
// each had the engine's DDR3 port waiting.
//
// +timed=FILE: write k is not issued before its MAME time, line k of FILE "frame line" (525 lines
// a frame, scripts' gcu_regtap.lua with CORE_FIFO=1, aligned to gcu_writes.txt), one MAME frame
// to one 58.4875 Hz frame here, the first write at the start of a vblank. A write the GCU holds
// (a full queue, a frame register write waiting for the engine) is late, as on the board. With
// +scan=1 every frame shown is reported: its black pixels in each third of the 384 lines, and
// its late lines.

#include "Vtb_gcu.h"
#include "verilated.h"
#include <cstdio>
#include "../common/ddr3_model.h"
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

double sc_time_stamp() { return 0; }

static Vtb_gcu *t;
static Ddr3Model ddr;
static uint64_t clocks = 0;
static uint64_t rst_clk = 0;            // +rst: the clock the reset is raised for
static bool rst_hit = false, rst_busy = false;
static bool prof_on = false;
static uint64_t prof_n[32][32], prof_w[32][32];
static const char *st_name[32] = {"IDLE", "POP", "DEC", "WAIT", "CMD", "NEXT", "DLX", "DLF", "DLEND",
    "VGET", "VPOP", "VDEC", "VFL", "FROW", "FNXT", "OD1", "OD2", "OD3", "OD4", "OSET", "OROW", "OCH",
    "OPX", "ODRN", "OCHN", "CROW", "CPX", "CDRN", "CNXT", "RWIN", "OWD", "OBG"};

// +timed with +scan=1: per-frame black pixel counts by third
static bool mon_on = false;
static int mon_x = 0, mon_y = -1, mon_de = 0, mon_vs = 1, mon_fr = 0;
static long mon_blk[3];
static unsigned mon_late = 0;

static void mon_tick() {
    if (t->vid_vs && !mon_vs) {
        if (mon_y >= 0) {
            printf("  frame %2d: black %6ld %6ld %6ld (of 65536 each), late lines %u, engine %s\n", mon_fr,
                   mon_blk[0], mon_blk[1], mon_blk[2], (unsigned)(t->late - mon_late),
                   t->gcu_idle ? "idle" : "busy");
        }
        mon_fr++;
        mon_late = t->late;
        mon_y = -1;
        mon_blk[0] = mon_blk[1] = mon_blk[2] = 0;
    }
    mon_vs = t->vid_vs;
    if (!t->ce_pix) {
        return;
    }
    int de = !(t->vid_hb || t->vid_vb);
    if (de && !mon_de) {
        mon_x = 0;
        mon_y++;
    }
    if (de) {
        if (mon_x < 512 && mon_y >= 0 && mon_y < 384 && t->vid_r == 0 && t->vid_g == 0 && t->vid_b == 0) {
            mon_blk[mon_y / 128]++;
        }
        mon_x++;
    }
    mon_de = de;
}

static void tick() {
    if (mon_on) {
        mon_tick();
    }
    if (rst_clk && clocks == rst_clk) {
        rst_hit = true; rst_busy = !t->gcu_idle;
        t->reset = 1; t->eval();
    }
    if (prof_on) {
        unsigned s = t->prof & 31, r = s == 3 ? t->prof >> 5 & 31 : 0;
        prof_n[s][r]++;
        if (t->prof >> 10 & 1) prof_w[s][r]++;
    }
    ddr.sample(t);
    t->clk = 1; t->eval();
    ddr.drive(t);
    if (rst_clk && clocks == rst_clk) t->reset = 0;
    t->clk = 0; t->eval();
    clocks++;
}

static std::vector<uint32_t> load_words(const std::string &p) {
    std::vector<uint32_t> v(0x800000);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f || fread(v.data(), 4, v.size(), f) != v.size()) { fprintf(stderr, "cannot read %s\n", p.c_str()); exit(1); }
    fclose(f);
    return v;
}

static void bus_write(uint32_t a, uint32_t d, uint32_t mask) {
    uint32_t be = 0;
    for (int b = 0; b < 4; b++) if (mask >> 8 * b & 0xFF) be |= 1u << b;
    t->req = 1; t->we = 1; t->addr = a & 0xFF; t->be = be; t->wdata = d;
    uint64_t start = clocks;
    do {
        tick();
        if (clocks - start > 50000000) {
            fprintf(stderr, "write %02X never taken; engine state %u, rd_iss %u, rd_rcv %u, wr_on %u, wr_kill %u, ddr3 %u, queue %u\n",
                    a & 0xFF, t->dbg >> 24 & 31, t->dbg >> 16 & 255, t->dbg >> 8 & 255, t->dbg >> 7 & 1,
                    t->dbg >> 6 & 1, t->dbg >> 4 & 3, t->dbg & 15);
            exit(1);
        }
    } while (!t->ack);
    t->req = 0;
    tick();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string win = "debug/ppp11-vram21400";
    long limit = 0, rst_at = 0;
    int scan = 0;
    bool prof = false, skip = false;
    std::string dump, timed;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("+win=", 0) == 0) win = a.substr(5);
        else if (a.rfind("+lat=", 0) == 0) ddr.lat = atoi(a.c_str() + 5);
        else if (a.rfind("+busy=", 0) == 0) ddr.busy = atoi(a.c_str() + 6);
        else if (a.rfind("+gap=", 0) == 0) ddr.gap = atoi(a.c_str() + 5);
        else if (a.rfind("+scan=", 0) == 0) scan = atoi(a.c_str() + 6);
        else if (a.rfind("+limit=", 0) == 0) limit = atol(a.c_str() + 7);
        else if (a.rfind("+rst=", 0) == 0) rst_at = atol(a.c_str() + 5);
        else if (a == "+prof") prof = true;
        else if (a.rfind("+dump=", 0) == 0) dump = a.substr(6);  // the VRAM at the end, as vram_out.raw
        else if (a == "+skip") skip = true;   // fb_gcu skip held: no draw command draws
        else if (a.rfind("+timed=", 0) == 0) timed = a.substr(7);
    }

    std::vector<uint32_t> vin = load_words(win + "/vram_in.raw");
    for (uint32_t i = 0; i < Ddr3Model::BEATS; i++)
        ddr.mem[i] = (uint64_t)vin[2 * i + 1] << 32 | vin[2 * i];

    t = new Vtb_gcu;
    t->scan = scan != 0;
    t->stacked = scan == 2;
    t->skip = skip;
    t->reset = 1; t->por = 1;
    for (int i = 0; i < 8; i++) tick();
    t->reset = 0; t->por = 0;
    tick();

    // the register file as captured (scripts/gcu_model.py)
    std::vector<std::pair<unsigned, unsigned>> regs;
    FILE *f = fopen((win + "/regs_in.txt").c_str(), "r");
    if (!f) { fprintf(stderr, "no regs_in.txt\n"); return 1; }
    unsigned a, v;
    while (fscanf(f, "%x %x", &a, &v) == 2)
        if ((a < 0x60 && a != 0x54 && a != 0x58) || a == 0x60 || a == 0x64 || a == 0x68 || a == 0x6C)
            regs.push_back({a, v});
    fclose(f);
    // a window whose CRTC registers MAME left at 0 (bm3: the mode comes from control_w) scans out
    // the 512 x 384 mode of fb_gcu_disp's test picture
    static const unsigned crtc512[3] = {0x01FF0447, 0x017F0515, 0x5F030064};
    bool crtc0 = false;
    for (auto &r : regs) {
        if (r.first == 0x00 && r.second == 0) {
            crtc0 = true;
        }
    }
    if (crtc0) {
        for (auto &r : regs) {
            if (r.first <= 0x08) {
                r.second = crtc512[r.first >> 2];
            }
        }
    }
    for (auto &r : regs) bus_write(r.first, r.second, 0xFFFFFFFF);

    struct W { uint32_t a, m, d; };
    std::vector<W> wr;
    f = fopen((win + "/gcu_writes.txt").c_str(), "r");
    if (!f) { fprintf(stderr, "no gcu_writes.txt\n"); return 1; }
    char rw;
    unsigned m, d;
    while (fscanf(f, " %c %x %x %x", &rw, &a, &m, &d) == 4) wr.push_back({a, m, d});
    fclose(f);
    if (limit && (size_t)limit < wr.size()) wr.resize(limit);

    const double frame = 66.667e6 / 58.4875;
    std::vector<uint64_t> due;            // +timed: each write's earliest clock, from the window's start
    if (!timed.empty()) {
        f = fopen(timed.c_str(), "r");
        if (!f) {
            fprintf(stderr, "no %s\n", timed.c_str());
            return 1;
        }
        long fr, ln, s0 = -1;
        while (fscanf(f, "%ld %ld", &fr, &ln) == 2) {
            long s = fr * 525 + ln;
            if (s0 < 0) {
                s0 = s;
            }
            due.push_back((uint64_t)((s - s0) * frame / 525));
        }
        fclose(f);
        if (due.size() < wr.size()) {
            fprintf(stderr, "%s: %zu times for %zu writes\n", timed.c_str(), due.size(), wr.size());
            return 1;
        }
        if (scan) {
            int vb = t->vid_vb;
            while (!(t->vid_vb && !vb)) {
                vb = t->vid_vb;
                tick();
            }
            mon_on = true;
        }
    }
    uint64_t late_w = 0, late_max = 0;

    uint64_t c0 = clocks, cmds = 0;
    ddr.rd_beats = ddr.wr_beats = 0;
    if (rst_at) rst_clk = c0 + rst_at;
    prof_on = prof;
    for (size_t i = 0; i <= wr.size(); i++) {
        if (i < wr.size()) {
            if (!due.empty()) {
                while (clocks - c0 < due[i]) {
                    tick();
                }
            }
            uint64_t w0 = clocks;
            bus_write(wr[i].a, wr[i].d, wr[i].m);
            if (!due.empty() && clocks - w0 > 4) {
                late_w++;
                late_max = std::max(late_max, (uint64_t)(clocks - w0));
            }
            if (t->cmd_v) cmds++;
        } else while (!t->gcu_idle && !rst_hit) tick();
        if (rst_hit) {
            uint64_t r0 = clocks;
            while (!t->gcu_idle) tick();
            fprintf(stderr, "reset at clock %lu (%s, after write %zu), idle %lu clocks later; replaying\n",
                    (unsigned long)(rst_clk - c0), rst_busy ? "busy" : "idle", i, (unsigned long)(clocks - r0));
            for (uint32_t k = 0; k < Ddr3Model::BEATS; k++)
                ddr.mem[k] = (uint64_t)vin[2 * k + 1] << 32 | vin[2 * k];
            for (auto &r : regs) bus_write(r.first, r.second, 0xFFFFFFFF);
            rst_hit = false; rst_clk = 0;
            i = (size_t)-1;
        }
    }
    while (!t->gcu_idle) tick();
    prof_on = false;
    for (int i = 0; i < 64; i++) tick();
    uint64_t c = clocks - c0;
    if (prof) {
        std::vector<std::pair<uint64_t, int>> v;
        for (int s = 0; s < 32; s++) for (int r = 0; r < 32; r++) if (prof_n[s][r]) v.push_back({prof_n[s][r], s * 32 + r});
        std::sort(v.rbegin(), v.rend());
        for (auto &e : v) {
            int s = e.second / 32, r = e.second % 32;
            char n[32];
            snprintf(n, sizeof n, s == 3 ? "WAIT>%s" : "%s", s == 3 ? st_name[r] : st_name[s]);
            printf("  %-10s %10lu clocks %5.1f%%, port waiting %lu\n", n, (unsigned long)e.first,
                   100.0 * e.first / c, (unsigned long)prof_w[s][r]);
        }
    }

    std::vector<uint32_t> vout = load_words(win + "/vram_out.raw");
    if (!dump.empty()) {
        FILE *df = fopen(dump.c_str(), "wb");
        for (uint32_t i = 0; i < Ddr3Model::BEATS; i++) {
            uint32_t w[2] = {(uint32_t)ddr.mem[i], (uint32_t)(ddr.mem[i] >> 32)};
            fwrite(w, 4, 2, df);
        }
        fclose(df);
    }
    long bad = 0, shown = 0;
    for (uint32_t i = 0; i < Ddr3Model::BEATS; i++) {
        uint32_t w[2] = {(uint32_t)ddr.mem[i], (uint32_t)(ddr.mem[i] >> 32)};
        for (int k = 0; k < 2; k++) {
            uint32_t got = w[k], exp = vout[2 * i + k];
            if (got == exp) continue;
            for (int h = 0; h < 2; h++) {
                uint16_t g = got >> 16 * (1 - h), e = exp >> 16 * (1 - h);
                if (g == e) continue;
                bad++;
                if (shown++ < 12)
                    fprintf(stderr, "  pixel %06X: %04X, MAME %04X\n", 2 * (2 * i + k) + h, g, e);
            }
        }
    }

    if (!due.empty()) {
        printf("timed: %lu writes held, longest %lu clocks\n", (unsigned long)late_w, (unsigned long)late_max);
    }
    mon_on = false;
    printf("%zu writes, %lu clocks (%.1f%% of 8 frames), DDR3 %lu read beats %lu write beats, lat %d busy %d%%%s\n",
           wr.size(), (unsigned long)c, 100.0 * c / (8 * frame), (unsigned long)ddr.rd_beats,
           (unsigned long)ddr.wr_beats, ddr.lat, ddr.busy, scan ? ", scan-out" : "");
    printf("VRAM diff: %ld of %u pixels\n", bad, 2 * 0x800000u);

    long sbad = 0;
    if (scan == 2) printf("stacked scan-out: late lines %u\n", t->late);
    else if (scan) {
        // the frame after the next vsync is built from the registers the window left
        std::vector<uint32_t> ref(512 * 384);
        f = fopen((win + "/screen_out.bin").c_str(), "rb");
        if (!f || fread(ref.data(), 4, ref.size(), f) != ref.size()) { fprintf(stderr, "no screen_out.bin\n"); return 1; }
        fclose(f);
        for (int k = 0; k < 2; k++) { int vs = t->vid_vs; while (!(t->vid_vs && !vs)) { vs = t->vid_vs; tick(); } }
        int x = 0, y = -1, prev_de = 0, seen = 0, vs = 1;
        while (true) {
            tick();
            if (t->vid_vs && !vs) break;
            vs = t->vid_vs;
            if (!t->ce_pix) continue;
            int de = !(t->vid_hb || t->vid_vb);
            if (de && !prev_de) { x = 0; y++; }
            if (de) {
                uint32_t got = (uint32_t)t->vid_r << 16 | t->vid_g << 8 | t->vid_b;
                uint32_t exp = (x < 512 && y < 384) ? ref[y * 512 + x] & 0xFFFFFF : 0xFFFFFFFF;
                if (got != exp && sbad++ < 10) fprintf(stderr, "  screen %d,%d: %06X, MAME %06X\n", x, y, got, exp);
                seen++; x++;
            }
            prev_de = de;
        }
        printf("screen diff: %ld of %d pixels (%d seen); late lines %u\n", sbad, 512 * 384, seen, t->late);
        if (seen != 512 * 384 || t->late) sbad++;
    }
    delete t;
    return (bad || sbad) ? 1 : 0;
}
