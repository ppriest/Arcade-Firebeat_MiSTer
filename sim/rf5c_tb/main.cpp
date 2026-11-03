// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_rf5c400 against sim/rf5c_tb/rf5c_ref.py: the reference's register writes (regs.bin) through
// the 68000's port and its wave RAM writes (mem.bin) straight into the bench's memory, each
// before the sample its index names, then every output sample against ref.bin.
//
//     python sim/rf5c_tb/rf5c_ref.py debug/popn4-rf5c obj_verilator/rf5c 66.4 69.4
//     scripts/run_verilator.sh rf5c_tb +dir=obj_verilator/rf5c +wave=debug/popn4-rf5c/waveram0.bin
#include "Vtb_rf5c.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::string arg(const char *n, const char *d) {
    const char *v = Verilated::commandArgsPlusMatch(n);
    std::string s = v && *v ? v : "";
    std::string k = std::string("+") + n + "=";
    return s.rfind(k, 0) == 0 ? s.substr(k.size()) : d;
}

template <class T> static std::vector<T> load(const std::string &p) {
    std::vector<T> v;
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { printf("FAIL %s\n", p.c_str()); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    v.resize(n / sizeof(T));
    if (fread(v.data(), sizeof(T), v.size(), f) != v.size()) { printf("FAIL read %s\n", p.c_str()); exit(1); }
    fclose(f);
    return v;
}

#pragma pack(push, 1)
struct Reg { uint32_t k; uint16_t off, d; };
struct Mem { uint32_t k, a; uint16_t d; };
#pragma pack(pop)

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string dir = arg("dir", "obj_verilator/rf5c");
    auto wave = load<uint16_t>(arg("wave", "debug/popn4-rf5c/waveram0.bin"));
    auto regs = load<Reg>(dir + "/regs.bin");
    auto mems = load<Mem>(dir + "/mem.bin");
    auto ref  = load<int16_t>(dir + "/ref.bin");
    wave.resize(1 << 24);
    if (regs.empty()) { printf("FAIL no register writes\n"); return 1; }
    uint32_t k0 = regs[0].k;
    for (auto &r : regs) if (r.k < k0) k0 = r.k;

    Vtb_rf5c *t = new Vtb_rf5c;
    bool macked = false;
    long pulses = 0;
    auto clk = [&]() {
        // the memory: a word a clock after the request
        if (t->m_req && !macked) {
            if (t->m_we) wave[t->m_addr] = t->m_wd;
            t->m_rd = wave[t->m_addr]; t->m_ack = 1; macked = true;
        } else { t->m_ack = 0; macked = false; }
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        if (t->sample) pulses++;
    };
    auto wr = [&](uint16_t off, uint16_t d) {
        t->req = 1; t->we = 1; t->addr = off; t->wd = d;
        for (int i = 0; i < 64 && !t->ack; i++) clk();
        if (!t->ack) { printf("FAIL no ack at %03X\n", off); exit(1); }
        t->req = 0; clk();
    };

    t->reset = 1; t->req = 0; t->m_ack = 0;
    for (int i = 0; i < 16; i++) clk();
    t->reset = 0;

    size_t ri = 0, mi = 0;
    long bad = 0, worst = 0, n = (long)ref.size() / 2;
    for (long s = 0; s < n; s++) {
        uint32_t k = k0 + s;
        while (mi < mems.size() && mems[mi].k <= k) { wave[mems[mi].a] = mems[mi].d; mi++; }
        while (ri < regs.size() && regs[ri].k <= k) { wr(regs[ri].off, regs[ri].d); ri++; }
        if (s == 0) {               // the state written, the next sample is k0's
            long p = pulses;
            while (pulses == p) clk();
        }
        long p = pulses;
        while (pulses == p) clk();
        int16_t ol = (int16_t)t->out_l, orr = (int16_t)t->out_r;
        int dl = ol - ref[2 * s], dr = orr - ref[2 * s + 1];
        int d = abs(dl) > abs(dr) ? abs(dl) : abs(dr);
        if (d > worst) worst = d;
        if (d > 0 && bad++ < 10)
            printf("sample %ld (k %u): rtl %d %d, ref %d %d\n", s, k, ol, orr, ref[2 * s], ref[2 * s + 1]);
    }
    printf("%ld samples, %ld differ, worst %ld\n%s\n", n, bad, worst, bad ? "FAIL" : "PASS");
    delete t;
    return bad ? 1 : 0;
}
