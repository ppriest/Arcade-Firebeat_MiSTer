// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_ata's slave access log (docs/STATE.md). Replays a scripts/mame/atatap.lua log
// ("frame R|W cs reg data", the bus halfword) from +from=FRAME to +to=FRAME into fb_ata, an access
// every 200 clocks, then prints the log as the state dump holds it: "n W|R cs reg data repeats".
//
//     scripts/run_verilator.sh ata_tb +log=debug/ppp11-atatap/ata.txt +from=9433 +to=9433
#include "Vtb_ata.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>

double sc_time_stamp() { return 0; }

static std::string arg(const char *n, const char *d) {
    const char *v = Verilated::commandArgsPlusMatch(n);
    std::string s = v && *v ? v : "";
    std::string k = std::string("+") + n + "=";
    return s.rfind(k, 0) == 0 ? s.substr(k.size()) : d;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_ata *t = new Vtb_ata;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    std::string lf = arg("log", "");
    long from = atol(arg("from", "0").c_str()), to = atol(arg("to", "0").c_str());
    FILE *f = fopen(lf.c_str(), "r");
    if (!f) { printf("FAIL no log %s\n", lf.c_str()); return 1; }

    t->reset = 1; t->por = 1; t->req = 0; t->lg_a = 0;
    for (int i = 0; i < 16; i++) tick();
    t->reset = 0; t->por = 0;
    for (int i = 0; i < 100; i++) tick();

    char line[256];
    long n = 0;
    while (fgets(line, sizeof line, f)) {
        long fr; char rw; int cs, reg; unsigned d;
        if (sscanf(line, "%ld %c %d %d %x", &fr, &rw, &cs, &reg, &d) != 5 || fr < from) continue;
        if (fr > to) break;
        t->req = 1; t->we = rw == 'W'; t->cs1 = cs; t->off = reg;
        t->wdata = (uint16_t)(((d & 0xff) << 8) | (d >> 8));     // the bus halfword byte-swapped
        int w = 0;
        while (!t->ack && w++ < 100) tick();
        if (!t->ack) { printf("FAIL no ack at access %ld\n", n); return 1; }
        t->req = 0; tick();
        for (int i = 0; i < 200; i++) tick();
        n++;
    }
    fclose(f);

    auto rd = [&](unsigned a) { t->lg_a = a; tick(); tick(); return (uint32_t)t->lg_d; };
    uint32_t cnt = rd(0x800);
    printf("%ld accesses replayed, %u log entries\n", n, cnt);
    for (uint32_t i = cnt > 1024 ? cnt - 1024 : 0; i < cnt; i++) {
        uint32_t w0 = rd((i % 1024) * 2), w1 = rd((i % 1024) * 2 + 1);
        printf("%u %c %u %u %04X %u t%u\n", i, (w0 >> 31) ? 'W' : 'R', (w0 >> 30) & 1, (w0 >> 27) & 7,
               w0 & 0xffff, ((w0 >> 16) & 0x3ff) + 1, w1);
    }
    delete t;
    return 0;
}
