// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_atapi_absent against fb_atapi CSEL 1 with no disc: bm3's main-bus ATA accesses
// (sim/atapi_absent_tb/ata_script.py's script of a PPC capture), 64 clocks apart and 150,000
// clocks (past the 2 ms diagnostic) at each new frame, then SRST pulses at gaps around the
// diagnostic's length. Every clock: DASP and PDIAG equal, and the full drive never answering or
// interrupting (the stub does neither), and the stub's `bad` low.
//
//     python sim/atapi_absent_tb/ata_script.py debug/bm3-boot/io.txt debug/bm3-boot/ata_script.txt
//     scripts/run_verilator.sh atapi_absent_tb +script=debug/bm3-boot/ata_script.txt
#include "Vtb_atapi_absent.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

double sc_time_stamp()
{
    return 0;
}

static Vtb_atapi_absent *t;
static uint64_t cyc = 0;
static int us_n = 0;
static int us_ph = 0;
static long fails = 0;

static void tick()
{
    // the drives' microsecond as fb_ata makes it: 66, 67, 67 clocks
    t->tick_us = 0;
    us_n++;
    if (us_n == (us_ph == 0 ? 66 : 67)) {
        us_n = 0;
        us_ph = (us_ph == 2) ? 0 : us_ph + 1;
        t->tick_us = 1;
    }
    t->clk = 0;
    t->eval();
    t->clk = 1;
    t->eval();
    cyc++;
    t->acc = 0;
    bool bad = t->f_dasp != t->s_dasp || t->f_pdiag != t->s_pdiag || t->f_resp || t->f_irq || t->s_bad;
    if (bad) {
        fails++;
        if (fails <= 20) {
            printf("  clock %llu: DASP %d/%d PDIAG %d/%d resp %d irq %d bad %d\n", (unsigned long long)cyc,
                   t->f_dasp, t->s_dasp, t->f_pdiag, t->s_pdiag, t->f_resp, t->f_irq, t->s_bad);
        }
    }
}

static void idle(int n)
{
    for (int i = 0; i < n; i++) {
        tick();
    }
}

static void access(bool we, bool cs1, int off, int wd)
{
    t->acc = 1;
    t->we = we;
    t->cs1 = cs1;
    t->off = off;
    t->wd = wd;
    tick();
    idle(63);
}

static void srst(int on_clocks, int off_clocks)
{
    access(true, true, 6, 0x0C);
    idle(on_clocks);
    access(true, true, 6, 0x08);
    idle(off_clocks);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    t = new Vtb_atapi_absent;
    const char *a = Verilated::commandArgsPlusMatch("script=");
    std::string path = (a && *a) ? std::string(a + 8) : "debug/bm3-boot/ata_script.txt";
    std::ifstream sc(path);
    if (!sc) {
        printf("FAIL no %s\n", path.c_str());
        return 1;
    }
    t->reset = 1;
    idle(4);
    t->reset = 0;

    long n = 0;
    std::string line;
    while (std::getline(sc, line)) {
        std::istringstream s(line);
        std::string op;
        s >> op;
        if (op == "F") {
            idle(150000);
        } else if (op == "A") {
            int we;
            int cs1;
            int off;
            int wd;
            s >> we >> cs1 >> off >> std::hex >> wd;
            access(we, cs1, off, wd);
            n++;
        }
    }
    // SRST in and around the diagnostic: during the power-on one, short and long holds, a new SRST
    // before the last diagnostic ended
    t->reset = 1;
    idle(4);
    t->reset = 0;
    srst(100, 1000);
    srst(100, 200000);
    srst(5000, 50000);
    srst(10, 140000);
    srst(10, 128000);
    srst(10, 200000);
    printf("%ld accesses, %llu clocks, %ld clocks differ\n", n, (unsigned long long)cyc, fails);
    printf(fails ? "FAIL\n" : "PASS\n");
    delete t;
    return fails ? 1 : 0;
}
