// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_atahdd against MAME's bm3: the SPU 68000's accesses to the drive (scripts/mame/popn_spu.lua's
// spu.txt, the 300000-30000F and 340000-34000F lines) replayed at MAME's times, 15 ns a clock,
// from shortly before the first. Every read is compared: the data register's 16 bits, the other
// registers' low byte (the high byte: HARDWARE_NOTES "bm3's boot against MAME"). The bench plays
// firebeat.cpp's DMA (spu_dma_callback: a word as DMARQ rises, then one every 350 ns while it
// stays up, into wave RAM at the bank (260000) and address (240000, 250000) the 68000 wrote) and
// compares each word the drive gave by DMA with MAME's wave RAM at CORE_TO (waveram.bin). It plays
// the slot from sector files cut from the CHD (<dir>/<lba>.bin, `chdman extractraw`), +lat
// microseconds before a request's first word, then a word a clock.
//
//     scripts/run_verilator.sh hdd_tb +cap=debug/bm3-spu +img=debug/bm3-spu/hdd
//         [+geo=32192,16,32] [+lat=0] [+diffs=20] [+until=<seconds>]
#include "Vtb_hdd.h"
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <dirent.h>

double sc_time_stamp() { return 0; }

static std::string arg(const char *n, const char *d) {
    const char *v = Verilated::commandArgsPlusMatch(n);
    std::string s = v && *v ? v : "";
    std::string k = std::string("+") + n + "=";
    return s.rfind(k, 0) == 0 ? s.substr(k.size()) : d;
}

struct Acc { double t; bool w; uint32_t a; uint16_t d; };
struct Range { uint32_t lba; std::vector<uint8_t> b; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const std::string cap = arg("cap", "debug/bm3-spu");
    const std::string img = arg("img", "debug/bm3-spu/hdd");
    const int ndiff = atoi(arg("diffs", "20").c_str());
    const double lat_us = atof(arg("lat", "0").c_str());
    const double until = atof(arg("until", "1e9").c_str());
    unsigned g_c = 32192, g_h = 16, g_s = 32;
    sscanf(arg("geo", "32192,16,32").c_str(), "%u,%u,%u", &g_c, &g_h, &g_s);
    const uint32_t total = g_c * g_h * g_s;

    // MAME's accesses
    std::vector<Acc> acc;
    {
        FILE *f = fopen((cap + "/spu.txt").c_str(), "r");
        if (!f) { printf("no %s/spu.txt\n", cap.c_str()); return 1; }
        char line[160];
        while (fgets(line, sizeof line, f)) {
            double t; long fr; char side, rw; unsigned a, d, m;
            if (sscanf(line, "%lf %ld %c %c %x %x %x", &t, &fr, &side, &rw, &a, &d, &m) != 7 || side != 'S') continue;
            bool ata = (a >= 0x300000 && a <= 0x30000f) || (a >= 0x340000 && a <= 0x34000f);
            bool dma = rw == 'W' && (a == 0x240000 || a == 0x250000 || a == 0x260000);
            if ((ata || dma) && t <= until) acc.push_back({t, rw == 'W', a, (uint16_t)d});
        }
        fclose(f);
    }
    // the image's sectors
    std::vector<Range> rng;
    if (DIR *dp = opendir(img.c_str())) {
        while (dirent *e = readdir(dp)) {
            if (!strstr(e->d_name, ".bin")) continue;
            Range r; r.lba = strtoul(e->d_name, nullptr, 10);
            FILE *f = fopen((img + "/" + e->d_name).c_str(), "rb");
            fseek(f, 0, SEEK_END); r.b.resize(ftell(f)); fseek(f, 0, SEEK_SET);
            if (fread(r.b.data(), 1, r.b.size(), f) != r.b.size()) return 1;
            fclose(f);
            rng.push_back(std::move(r));
        }
        closedir(dp);
    }
    long missing = 0;
    auto sector_word = [&](uint32_t lba, int w) -> uint16_t {
        for (auto &r : rng)
            if (lba >= r.lba && (uint64_t)(lba - r.lba) * 512 < r.b.size()) {
                size_t o = (size_t)(lba - r.lba) * 512 + 2 * w;
                return r.b[o] | r.b[o + 1] << 8;
            }
        if (w == 0) missing++;
        return 0;
    };
    // MAME's wave RAM at the end
    std::vector<uint16_t> wave(16 << 20);
    {
        FILE *f = fopen((cap + "/waveram.bin").c_str(), "rb");
        if (!f || fread(wave.data(), 2, wave.size(), f) != wave.size()) { printf("no waveram.bin\n"); return 1; }
        fclose(f);
    }
    printf("%zu accesses, %zu sector files, geometry %u/%u/%u\n", acc.size(), rng.size(), g_c, g_h, g_s);

    double t0 = 0;
    for (auto &x : acc) if (x.a >= 0x300000) { t0 = x.t - 0.05; break; }
    auto cyc = [&](double t) -> uint64_t { return t <= t0 ? 0 : (uint64_t)llround((t - t0) * 1e9 / 15.0); };

    Vtb_hdd *t = new Vtb_hdd;
    t->clk = 0; t->reset = 1; t->acc = 0; t->dma_acc = 0; t->rq_done = 0; t->bw_we = 0;
    t->have_disk = 1; t->total = total; t->cyls = g_c; t->heads = g_h; t->spt = g_s;

    size_t ai = 0;
    uint64_t c = 0, last_strobe = 0;
    int pend_rd = -1;                   // an access answered the clock after
    bool pend_dma = false;
    uint32_t dma_lo = 0, dma_hi = 0, bank = 0, dma_a = 0;
    bool dmarq_q = false;
    double dma_next_ns = -1;
    // the slot
    bool s_on = false; uint64_t s_at = 0; uint32_t s_lba = 0; int s_n = 0, s_w = 0;
    long n_rd = 0, n_data = 0, n_dma = 0, d_reg = 0, d_data = 0, d_dma = 0, n_req = 0;
    std::map<uint32_t, uint16_t> dma_w;

    auto tick = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); c++; };

    for (int i = 0; i < 8; i++) tick();
    t->reset = 0;

    const uint64_t c_end = cyc(acc.back().t) + (uint64_t)(0.5e9 / 15);   // half a second past the last access
    bool capped = false;
    while (ai < acc.size() || pend_rd >= 0 || t->dmarq || s_on) {
        if (c >= c_end) { capped = true; break; }
        if ((c & ((1ull << 27) - 1)) == 0) {
            printf("  %.3f s: access %zu of %zu, dmarq %d, slot %d, BSY %d, DMA words %ld\n",
                   t0 + c * 15e-9, ai, acc.size(), t->dmarq, s_on, t->busy, n_dma);
            fflush(stdout);
        }
        // answers to last clock's strobes
        if (pend_rd >= 0) {
            const Acc &x = acc[pend_rd];
            bool data = x.a == 0x300000;
            uint16_t got = t->resp ? t->rd : 0xffff;
            bool ok = data ? got == x.d : (got & 0xff) == (x.d & 0xff);
            n_rd++; if (data) n_data++;
            if (!ok) {
                (data ? d_data : d_reg)++;
                if ((data ? d_data : d_reg) <= ndiff)
                    printf("  %.9f R %06X: MAME %04X, drive %04X%s\n", x.t, x.a, x.d, got, t->busy ? " (BSY)" : "");
            }
            pend_rd = -1;
        }
        if (pend_dma) {
            uint32_t a = (bank + dma_a) & 0xffffff;
            dma_w[a] = t->rd;
            dma_a++; n_dma++;
            pend_dma = false;
        }
        t->acc = 0; t->dma_acc = 0;

        // the slot
        t->bw_we = 0; t->rq_done = 0;
        if (t->rq && !s_on) {
            s_on = true; s_lba = t->rq_lba; s_n = t->rq_n; s_w = 0; n_req++;
            s_at = c + (uint64_t)(lat_us * 1000 / 15);
        } else if (s_on && c >= s_at) {
            if (s_w < 256 * s_n) {
                t->bw_we = 1; t->bw_a = s_w; t->bw_d = sector_word(s_lba + s_w / 256, s_w % 256); s_w++;
            } else { t->rq_done = 1; s_on = false; }
        }

        // a register access at its time, else a DMA word
        bool strobe_ok = c >= last_strobe + 2;
        if (ai < acc.size() && strobe_ok && c >= cyc(acc[ai].t)) {
            const Acc &x = acc[ai];
            if (x.a == 0x240000) { dma_lo = x.d; dma_a = dma_hi << 16 | dma_lo; }
            else if (x.a == 0x250000) { dma_hi = x.d; dma_a = dma_hi << 16 | dma_lo; }
            else if (x.a == 0x260000) bank = (uint32_t)x.d * (4 << 20);
            else {
                t->acc = 1; t->we = x.w; t->cs1 = x.a >= 0x340000; t->off = (x.a >> 1) & 7; t->wd = x.d;
                if (!x.w) pend_rd = (int)ai;
                last_strobe = c;
            }
            ai++;
        } else if (t->dmarq && strobe_ok) {
            double now = c * 15.0;
            if (!dmarq_q) dma_next_ns = now;
            if (now >= dma_next_ns) {
                t->dma_acc = 1; pend_dma = true; last_strobe = c;
                dma_next_ns += 350.0;
            }
        }
        dmarq_q = t->dmarq;
        tick();
    }

    for (auto &kv : dma_w) {
        if (wave[kv.first] != kv.second) {
            if (++d_dma <= ndiff) printf("  wave RAM %06X: MAME %04X, drive %04X\n", kv.first, wave[kv.first], kv.second);
        }
    }
    if (capped) printf("stopped half a second past the last access: dmarq %d, slot %d, BSY %d\n", t->dmarq, s_on, t->busy);
    printf("%llu clocks (%.3f s); %ld requests, %ld sectors outside the image files (read ahead)\n",
           (unsigned long long)c, c * 15e-9, n_req, missing);
    printf("reads %ld: registers %ld differ; data words %ld, %ld differ\n", n_rd, d_reg, n_data, d_data);
    printf("DMA words %ld (%zu addresses), %ld differ from MAME's wave RAM\n", n_dma, dma_w.size(), d_dma);
    delete t;
    return (capped || d_reg || d_data || d_dma) ? 1 : 0;
}
