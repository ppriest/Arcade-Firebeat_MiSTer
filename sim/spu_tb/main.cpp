// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_spu68k's 68000 against MAME's: the bus accesses scripts/mame/systrace.lua logs on :audiocpu
// (every write; reads of 200000-34000F, 400000-400FFF, 800000-FFFFFF; reads of the autovectors
// 60-7F), compared in order within each SR interrupt mask, so that where an interrupt lands in
// the program does not matter. Data is compared under the access's byte mask.
//
// What depends on where an interrupt lands is left out, on both sides: RAM writes to the three
// stacks interrupts were taken on in MAME's run (10DB00-10DFFF, 116400-1167FF, 13FE00-13FFFF:
// pushed PC and SR, and the handlers' register saves, at the interrupted depth). Handlers raise
// their mask to 7, so their saves cannot be told from the program's by mask. Every other access,
// RAM writes elsewhere included, is compared.
//
// The program ROM comes from +rom (big-endian words), the wave RAM is a 32 MB model, the
// RF5C400's reads are answered from MAME's. The run stops at the first SPU ATA access (step 3's
// bench) or after +max accesses compared.
//
//     python sim/spu_tb/prep.py      (the ROM, swapped, beside the trace)
//     scripts/run_verilator.sh spu_tb +trace=debug/popn4-68k/popn4_68k_sys.trace \
//         +rom=debug/popn4-68k/spu_rom.bin [+max=N]
#include "Vtb_spu.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::string arg(const char *n, const char *d) {
    const char *v = Verilated::commandArgsPlusMatch(n);
    std::string s = v && *v ? v : "";
    std::string k = std::string("+") + n + "=";
    return s.rfind(k, 0) == 0 ? s.substr(k.size()) : d;
}

struct Acc { long seq, frame; char rw; uint32_t addr, mask, data; int ipl; };

static bool logged(char rw, uint32_t a) {
    if (rw == 'w') return true;
    return (a >= 0x200000 && a <= 0x34000f) || (a >= 0x400000 && a <= 0x400fff) || a >= 0x800000 ||
           (a >= 0x60 && a <= 0x7f);
}
static bool ram_w(const Acc &r) { return r.rw == 'w' && r.addr >= 0x100000 && r.addr <= 0x13ffff; }
static bool vec_first(const Acc &r) { return r.rw == 'r' && r.addr >= 0x60 && r.addr <= 0x7c && !(r.addr & 3); }
static bool compared(const Acc &r) {
    bool stk = (r.addr >= 0x10db00 && r.addr < 0x10e000) || (r.addr >= 0x116400 && r.addr < 0x116800) ||
               r.addr >= 0x13fe00;
    return !(ram_w(r) && stk);
}

// the three pushes before a vector read, dropped from a window of the latest accesses
static void drop_pushes(std::deque<Acc> &win) {
    int n = 0;
    for (auto it = win.end(); it != win.begin() && n < 3;) {
        --it;
        if (ram_w(*it)) { it = win.erase(it); n++; }
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::assertOn(false);     // fx68k's unique cases are not all covered in reset
    long max = atol(arg("max", "0").c_str());

    std::vector<uint8_t> rom(0x80000, 0xff);
    FILE *rf = fopen(arg("rom", "debug/popn4-68k/spu_rom.bin").c_str(), "rb");
    if (!rf || fread(rom.data(), 1, rom.size(), rf) != rom.size()) { printf("FAIL rom\n"); return 1; }
    fclose(rf);

    // MAME's accesses, a queue per mask; RF5C400 reads also in their own queue for their data
    std::deque<Acc> q[8];
    std::deque<uint32_t> rf_reads;
    FILE *tf = fopen(arg("trace", "debug/popn4-68k/popn4_68k_sys.trace").c_str(), "r");
    if (!tf) { printf("FAIL trace\n"); return 1; }
    char line[256];
    long frame = 0, total = 0;
    std::deque<Acc> mwin;
    auto mame_out = [&](const Acc &r) {
        if (r.rw == 'r' && r.addr >= 0x400000 && r.addr <= 0x400fff) rf_reads.push_back(r.data);
        if (compared(r)) { q[r.ipl].push_back(r); total++; }
    };
    while (fgets(line, sizeof line, tf)) {
        if (line[0] == '#') { sscanf(line, "# frame %ld", &frame); continue; }
        Acc r; char rw[4]; unsigned ipl;
        if (sscanf(line, "%ld %3s %x %x %x %u", &r.seq, rw, &r.addr, &r.mask, &r.data, &ipl) != 6) continue;
        r.rw = rw[0]; r.frame = frame; r.ipl = ipl & 7;
        if (r.addr >= 0x300000 && r.addr <= 0x34000f) break;     // the first SPU ATA access
        if (vec_first(r)) drop_pushes(mwin);
        mwin.push_back(r);
        if (mwin.size() > 3) { mame_out(mwin.front()); mwin.pop_front(); }
    }
    for (auto &r : mwin) mame_out(r);
    fclose(tf);
    printf("MAME: %ld accesses compared to the first SPU ATA access (frame %ld)\n", total, frame);
    for (int k = 0; k < 8; k++) if (!q[k].empty()) printf("  mask %d: %zu\n", k, q[k].size());

    std::vector<uint16_t> wave(16u << 20, 0);
    Vtb_spu *t = new Vtb_spu;
    long clocks = 0, cmp = 0, pend = 0;
    bool done = false;
    int rc = 0;
    std::deque<Acc> rwin;

    auto check = [&](const Acc &r) {
        if (done || !compared(r)) return;
        int k = r.ipl;
        if (q[k].empty()) {
            printf("FAIL mask %d: RTL %c %06X %04X %04X, MAME has no more (%ld compared)\n",
                   k, r.rw, r.addr, r.mask, r.data, cmp);
            done = true; rc = 1; return;
        }
        Acc m = q[k].front(); q[k].pop_front();
        if (m.rw != r.rw || m.addr != r.addr || m.mask != r.mask || (m.data & m.mask) != (r.data & r.mask)) {
            printf("FAIL mask %d at compare %ld, %ld clocks (MAME seq %ld, frame %ld)\n"
                   "  RTL  %c %06X %04X %04X\n  MAME %c %06X %04X %04X\n",
                   k, cmp, clocks, m.seq, m.frame, r.rw, r.addr, r.mask, r.data & r.mask,
                   m.rw, m.addr, m.mask, m.data & m.mask);
            for (int i = 0; i < 6 && i < (int)q[k].size(); i++)
                printf("  next %c %06X %04X %04X\n", q[k][i].rw, q[k][i].addr, q[k][i].mask, q[k][i].data);
            done = true; rc = 1; return;
        }
        if (++cmp % 1000000 == 0)
            printf("  %ld compared, %ld clocks, MAME frame %ld\n", cmp, clocks, m.frame);
        if (max && cmp >= max) { printf("STOP +max\n"); done = true; }
    };

    auto step = [&]() {
        // the external bus, answered the clock after the request
        t->x_ack = 0;
        if (t->x_req && pend++ >= 1) {
            pend = 0;
            uint32_t a = t->x_addr;                 // word address
            uint16_t d = 0;
            switch (t->x_rgn) {
            case 0: d = (rom[(a * 2) & 0x7ffff] << 8) | rom[(a * 2 + 1) & 0x7ffff]; break;
            case 1: {
                uint16_t &w = wave[a & 0xffffff];
                if (t->x_we) {
                    if (t->x_be & 2) w = (w & 0x00ff) | (t->x_wd & 0xff00);
                    if (t->x_be & 1) w = (w & 0xff00) | (t->x_wd & 0x00ff);
                }
                d = w;
                break;
            }
            case 4:
                if (!t->x_we) {
                    if (rf_reads.empty()) { printf("FAIL RF5C400 read past MAME's\n"); done = true; rc = 1; }
                    else { d = rf_reads.front(); rf_reads.pop_front(); }
                }
                break;
            default:
                printf("STOP SPU ATA access at %06X after %ld compared, %ld clocks\n", a * 2, cmp, clocks);
                done = true;
                break;
            }
            t->x_rd = d; t->x_ack = 1;
        }
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        clocks++;
        if (!t->tr_valid || done) return;
        uint32_t info = t->tr_info;
        Acc r;
        r.seq = clocks; r.frame = 0;
        r.rw = (info >> 25) & 1 ? 'r' : 'w';
        r.addr = (info & 0x7fffff) << 1;
        r.mask = ((info >> 24) & 1 ? 0 : 0xff00) | ((info >> 23) & 1 ? 0 : 0x00ff);
        r.data = t->tr_data;
        r.ipl = t->sr_mask;
        if (!logged(r.rw, r.addr)) return;
        if (vec_first(r)) drop_pushes(rwin);
        rwin.push_back(r);
        if (rwin.size() > 3) { check(rwin.front()); rwin.pop_front(); }
    };

    t->rst = 1; t->x_ack = 0; t->pp_cs = 0; t->ata_irq = 0;
    for (int i = 0; i < 32; i++) step();
    t->rst = 0;
    while (!done) step();

    long left = 0;
    for (int k = 0; k < 8; k++) left += q[k].size();
    printf("%s: %ld compared, %ld left in MAME's queues, %ld clocks (%.2f s)\n",
           rc ? "FAIL" : "PASS", cmp, left, clocks, clocks / 66.6667e6);
    delete t;
    return rc;
}
