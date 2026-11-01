// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_ymz280b against MAME: replays a scripts/mame YMZ access log ("seconds R|W 7D000400 data
// mask"; mask FF000000 is offset 0, 00FF0000 offset 1) with the sound flash as port y's memory,
// an access placed before sample ceil(t * 88200). Checks every read against MAME's value and
// writes the 88.2 kHz output (s16 out_l, out_r) to +out=FILE, first sample index printed.
//
//     scripts/run_verilator.sh ymz_tb +log=debug/ymz_ref/ymz.txt +flash=debug/ymz_ref/nvram/ppp11 +out=FILE
#include "Vtb_ymz.h"
#include "verilated.h"
#include <cmath>
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

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<uint8_t> fl(0x400000, 0xff);
    std::string fd = arg("flash", "debug/ymz_ref/nvram/ppp11");
    for (int i = 0; i < 2; i++) {
        std::string p = fd + "/flash_snd" + std::to_string(i + 1);
        FILE *f = fopen(p.c_str(), "rb");
        if (!f || fread(&fl[i * 0x200000], 1, 0x200000, f) != 0x200000) { printf("FAIL %s\n", p.c_str()); return 1; }
        fclose(f);
    }
    FILE *lf = fopen(arg("log", "debug/ymz_ref/ymz.txt").c_str(), "r");
    FILE *of = fopen(arg("out", "obj_verilator/ymz.raw").c_str(), "wb");
    if (!lf || !of) { printf("FAIL files\n"); return 1; }

    Vtb_ymz *t = new Vtb_ymz;
    int ycnt = 0;
    long sample = -1;                   // index of the last sample the engine produced
    long first = -1;
    std::vector<int16_t> buf;
    auto clk = [&]() {
        if (t->y_req && ++ycnt >= 3) { t->y_ack = 1; t->y_rdata = fl[t->y_addr & 0x3fffff]; ycnt = 0; }
        else t->y_ack = 0;
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        if (t->tick) {
            // the previous tick's sample is in out_l/out_r by now
            if (sample >= 0 && first >= 0) { buf.push_back(t->out_l); buf.push_back(t->out_r); }
            sample++;
        }
    };
    t->reset = 1; t->req = 0;
    for (int i = 0; i < 16; i++) clk();
    t->reset = 0;

    char line[256];
    long n = 0, rd = 0, bad = 0, late = 0;
    while (fgets(line, sizeof line, lf)) {
        double s; char rw; unsigned a, d, m;
        if (sscanf(line, "%lf %c %x %x %x", &s, &rw, &a, &d, &m) != 5) continue;
        long k = (long)ceil(s * 88200.0);
        if (first < 0) { first = k; sample = k - 1; }
        // wait for the tick that produces sample k - 1, then the engine's run
        while (sample < k - 1) clk();
        int a0 = m == 0x00ff0000;
        t->req = 1; t->we = rw == 'W'; t->a0 = a0; t->wdata = a0 ? (d >> 16) & 0xff : d >> 24;
        int w = 0;
        while (!t->ack && w++ < 2000) clk();
        if (!t->ack) { printf("FAIL no ack at line %ld\n", n); return 1; }
        if (sample > k - 1) late++;
        t->req = 0; clk();
        if (rw == 'R') {
            unsigned want = a0 ? (d >> 16) & 0xff : d >> 24;
            rd++;
            if (t->rdata != want) {
                if (bad < 40) printf("MISMATCH %.9f %s got %02X want %02X\n", s, a0 ? "status" : "readback", t->rdata, want);
                bad++;
            }
        }
        n++;
    }
    for (int i = 0; i < 400 * 88200; i++) clk();     // one second after the last access
    fwrite(buf.data(), 2, buf.size(), of);
    fclose(of);
    printf("%ld accesses, %ld reads, %ld mismatches, %ld after their sample; first sample %ld, %zu samples\n",
           n, rd, bad, late, first, buf.size() / 2);
    delete t;
    return bad ? 1 : 0;
}
