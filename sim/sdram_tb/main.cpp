// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mister/firebeat_sdram.sv against a reference memory, on the 128 MB chip model, with clk at
// 66.667 MHz and clk_mem at 133.333 MHz (two clk_mem edges a clk, rising together):
//
//   1. a download of random halfwords, read back through the line and word ports;
//   2. random traffic on all three client ports over a few lines (line reads and writes, DMA line
//      reads, byte-enabled word writes and reads), every read checked;
//   3. +events=FILE: sim/ppc_tb's memory events (F fill, W write-back, D DMA line, with the clock
//      at one-clock memory and the idle flag) replayed in a closed loop, the CPU's fills and
//      write-backs one at a time after the compute time between them, the DMA's transfers
//      streamed beside it (see the replay). Reports the replay's clocks against the
//      recording's, the work clocks a frame, the fill latency and how busy the SDRAM was.
//
//     scripts/run_verilator.sh sdram_tb [+seed=N] [+ops=N] [+events=debug/ppp11-win21357/mem_events.txt +frames=2.1]

#include "Vtb_sdram.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <random>
#include <algorithm>

double sc_time_stamp() { return 0; }

static Vtb_sdram *t;
static std::vector<uint8_t> ref(128u << 20, 0);
static uint64_t clk_n = 0, mem_n = 0, mem_busy_n = 0;

// one clk cycle: clk_mem rises at its start and halfway, clk at its start
static void cycle() {
    t->clk = 1; t->clk_mem = 1; t->eval();
    mem_n++; mem_busy_n += t->mem_busy;
    t->clk_mem = 0; t->eval();
    t->clk = 0; t->clk_mem = 1; t->eval();
    mem_n++; mem_busy_n += t->mem_busy;
    t->clk_mem = 0; t->eval();
    clk_n++;
}

static uint32_t ref_word(uint32_t byte) {
    return (uint32_t)ref[byte] << 24 | (uint32_t)ref[byte + 1] << 16 | (uint32_t)ref[byte + 2] << 8 | ref[byte + 3];
}

static int errors = 0;
static void check_line(const char *who, uint32_t line, const uint32_t *got) {
    for (int k = 0; k < 4; k++) {
        uint32_t want = ref_word(line * 16 + 4 * k);
        if (got[k] != want && errors++ < 10)
            printf("MISMATCH %s line %07X word %d: got %08X want %08X\n", who, line, k, got[k], want);
    }
}

static void get_line(const VlWide<4> &w, uint32_t *out) { for (int k = 0; k < 4; k++) out[k] = w[k]; }
static void get_block(const VlWide<8> &w, uint32_t *out) { for (int k = 0; k < 8; k++) out[k] = w[k]; }
static void check_block(const char *who, uint32_t block, const uint32_t *got) {   // 32 bytes
    for (int l = 0; l < 2; l++) check_line(who, block * 2 + l, got + 4 * l);
}
static void set_line(VlWide<4> &w, const uint32_t *in) { for (int k = 0; k < 4; k++) w[k] = in[k]; }

// a transaction, held until acknowledged; returns the clocks from the request to the acknowledge
static int line_read(bool dma, uint32_t line, uint32_t *out) {
    if (dma) { t->m_req = 1; t->m_addr = line >> 1; } else { t->c_req = 1; t->c_we = 0; t->c_addr = line; }
    int n = 0;
    for (;;) {
        cycle(); n++;
        if (dma ? t->m_ack : t->c_ack) break;
        if (n > 100000) { printf("TIMEOUT line read\n"); exit(1); }
    }
    if (dma) {
        uint32_t b[8]; get_block(t->m_rdata, b);
        check_block("m block", line >> 1, b);
        for (int k = 0; k < 4; k++) out[k] = b[4 * (line & 1) + k];
        t->m_req = 0;
    } else {
        get_line(t->c_rdata, out); t->c_req = 0;
    }
    return n;
}

static int line_write(uint32_t line, const uint32_t *in) {
    t->c_req = 1; t->c_we = 1; t->c_addr = line; set_line(t->c_wdata, in);
    int n = 0;
    for (;;) { cycle(); n++; if (t->c_ack) break; if (n > 100000) { printf("TIMEOUT line write\n"); exit(1); } }
    t->c_req = 0; t->c_we = 0;
    for (int k = 0; k < 4; k++)
        for (int b = 0; b < 4; b++) ref[line * 16 + 4 * k + b] = (uint8_t)(in[k] >> (24 - 8 * b));
    return n;
}

static int word_op(bool we, uint32_t waddr, unsigned be, uint32_t din, uint32_t *dout) {
    t->w_req = 1; t->w_we = we; t->w_addr = waddr; t->w_be = be; t->w_wdata = din;
    int n = 0;
    for (;;) { cycle(); n++; if (t->w_ack) break; if (n > 100000) { printf("TIMEOUT word\n"); exit(1); } }
    t->w_req = 0; t->w_we = 0;
    if (we) {
        for (int b = 0; b < 4; b++)
            if (be & (8 >> b)) ref[waddr * 4 + b] = (uint8_t)(din >> (24 - 8 * b));
    } else if (dout) *dout = t->w_rdata;
    return n;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    unsigned seed = (s = Verilated::commandArgsPlusMatch("seed=")) && *s ? atoi(s + 6) : 1;
    long ops = (s = Verilated::commandArgsPlusMatch("ops=")) && *s ? atol(s + 5) : 20000;
    std::string events = (s = Verilated::commandArgsPlusMatch("events=")) && *s ? std::string(s + 8) : "";
    double frames = (s = Verilated::commandArgsPlusMatch("frames=")) && *s ? atof(s + 8) : 0;
    std::mt19937 rng(seed);

    t = new Vtb_sdram;
    t->init = 1; t->reset = 1;
    t->c_req = 0; t->m_req = 0; t->w_req = 0; t->d_we = 0;
    for (int i = 0; i < 16; i++) cycle();
    t->init = 0;
    for (int i = 0; i < 20000; i++) cycle();     // the controller's power-up and mode setting
    t->reset = 0;
    for (int i = 0; i < 16; i++) cycle();

    // 1. download 8 KB at two places, one in each chip
    uint32_t bases[2] = {0x0123400, 0x4567800};
    for (uint32_t base : bases)
        for (uint32_t i = 0; i < 4096; i++) {
            uint32_t a = base / 2 + i;
            uint16_t v = (uint16_t)rng();
            t->d_we = 1; t->d_addr = a; t->d_din = v;
            do cycle(); while (!t->d_ready);
            t->d_we = 0; cycle();
            while (!t->d_ready) cycle();
            ref[a * 2] = (uint8_t)(v >> 8); ref[a * 2 + 1] = (uint8_t)v;
        }
    for (int i = 0; i < 64; i++) cycle();
    for (uint32_t base : bases)
        for (uint32_t l = 0; l < 512; l++) {
            uint32_t got[4];
            line_read(l & 1, base / 16 + l, got);
            check_line("download", base / 16 + l, got);
        }
    printf("download: %d errors\n", errors);

    // 2. random traffic on a few lines
    int e0 = errors;
    uint32_t pool[8];
    for (int i = 0; i < 8; i++) pool[i] = (rng() & 0x7fffff) | (i & 1 ? 0x400000 : 0);
    for (long i = 0; i < ops; i++) {
        uint32_t line = pool[rng() % 8];
        uint32_t d[4];
        switch (rng() % 5) {
        case 0: line_read(false, line, d); check_line("c read", line, d); break;
        case 1: line_read(true, line, d); check_line("m read", line, d); break;
        case 2: for (int k = 0; k < 4; k++) d[k] = rng(); line_write(line, d); break;
        case 3: {
            unsigned be = rng() % 16;
            if (!be) be = 1;
            word_op(true, line * 4 + rng() % 4, be, rng(), nullptr);
            break;
        }
        default: {
            uint32_t w = line * 4 + rng() % 4, got = 0;
            word_op(false, w, 0, 0, &got);
            uint32_t want = ref_word(w * 4);
            if (got != want && errors++ < 10) printf("MISMATCH w read %07X: got %08X want %08X\n", w, got, want);
        }
        }
        if (rng() % 4 == 0) for (int g = rng() % 8; g > 0; g--) cycle();
    }
    printf("random: %ld operations, %d errors\n", ops, errors - e0);

    // 3. the closed-loop replay. Two agents in the same clocks: the CPU issues its fills and
    // write-backs on port c one at a time, each after the compute time it spent before it at
    // one-clock memory; the DMA streams a transfer's lines on port m while the CPU goes on. The
    // game starts a transfer and returns (80041838-80041884), and checks the GCU (80042B4C)
    // before the next: the CPU here waits only if it reaches a transfer while the last one runs.
    if (!events.empty()) {
        FILE *f = fopen(events.c_str(), "r");
        if (!f) { printf("cannot open %s\n", events.c_str()); return 1; }
        struct Ev { uint64_t t; char k; uint32_t a; int idle; };
        std::vector<Ev> ev;
        unsigned long long tt; char kk; unsigned aa; int ii;
        while (fscanf(f, "%llu %c %x %d", &tt, &kk, &aa, &ii) == 4) ev.push_back({tt, kk, aa, ii});
        fclose(f);
        // group: a CPU event, or a DMA transfer (its lines share one clock)
        struct Grp { uint64_t t; char k; int idle; std::vector<uint32_t> lines; };
        std::vector<Grp> g;
        for (const Ev &e : ev) {
            uint32_t line = (e.a & 0x7ffffff) >> 4;
            if (e.k == 'D' && !g.empty() && g.back().k == 'D' && g.back().t == e.t) g.back().lines.push_back(line);
            else g.push_back({e.t, e.k, e.idle, {line}});
        }
        int e1 = errors;
        uint64_t c0 = clk_n, m0 = mem_n, b0 = mem_busy_n;
        uint64_t work_rec = 0, work_rep = 0, fills = 0, fill_sum = 0, fill_max = 0, dma_wait = 0, dma_lines = 0;
        std::vector<uint64_t> fill_hist(8, 0);

        // the DMA agent
        std::vector<uint32_t> dq; size_t dpos = 0; bool m_busy = false;
        auto dma_step = [&]() {             // called once a clock, after cycle()
            if (m_busy && t->m_ack) {
                uint32_t b[8]; get_block(t->m_rdata, b); check_block("replay dma", dq[dpos], b);
                t->m_req = 0; m_busy = false; dpos++; dma_lines++;
            } else if (!m_busy && dpos < dq.size()) {
                t->m_req = 1; t->m_addr = dq[dpos]; m_busy = true;
            }
        };
        auto tick = [&]() { cycle(); dma_step(); };
        auto dma_running = [&]() { return dpos < dq.size() || m_busy; };

        // a CPU transaction on port c while the DMA agent runs
        auto cpu_fill = [&](uint32_t line) {
            t->c_req = 1; t->c_we = 0; t->c_addr = line;
            int n = 0;
            for (;;) { tick(); n++; if (t->c_ack) break; if (n > 100000) { printf("TIMEOUT\n"); exit(1); } }
            uint32_t d[4]; get_line(t->c_rdata, d); t->c_req = 0; check_line("replay fill", line, d);
            return n;
        };
        auto cpu_wb = [&](uint32_t line) {
            uint32_t d[4]; for (int k = 0; k < 4; k++) d[k] = (uint32_t)rng();
            t->c_req = 1; t->c_we = 1; t->c_addr = line; set_line(t->c_wdata, d);
            int n = 0;
            for (;;) { tick(); n++; if (t->c_ack) break; if (n > 100000) { printf("TIMEOUT\n"); exit(1); } }
            t->c_req = 0; t->c_we = 0;
            for (int k = 0; k < 4; k++) for (int b = 0; b < 4; b++) ref[line * 16 + 4 * k + b] = (uint8_t)(d[k] >> (24 - 8 * b));
            return n;
        };

        uint64_t prev_t = g.empty() ? 0 : g[0].t;
        int prev_cost = 0;
        for (const Grp &e : g) {
            int64_t gap = (int64_t)(e.t - prev_t) - prev_cost;
            if (gap < 0) gap = 0;
            uint64_t start = clk_n;
            for (int64_t i = 0; i < gap; i++) tick();
            if (e.k == 'F') {
                int n = cpu_fill(e.lines[0]);
                fills++; fill_sum += n; fill_max = std::max<uint64_t>(fill_max, n);
                fill_hist[std::min(7, n / 8)]++;
            } else if (e.k == 'W') {
                cpu_wb(e.lines[0]);
            } else {
                uint64_t w0 = clk_n;
                while (dma_running()) tick();       // the previous transfer still runs
                dma_wait += clk_n - w0;
                dq.clear();                         // the transfer's 32-byte blocks
                for (uint32_t l : e.lines) if (dq.empty() || dq.back() != l >> 1) dq.push_back(l >> 1);
                dpos = 0;
            }
            uint64_t spent = clk_n - start;
            if (!e.idle) { work_rep += spent; work_rec += (uint64_t)gap + (e.k == 'D' ? 0 : 4); }
            prev_cost = e.k == 'D' ? 0 : 4;
            prev_t = e.t;
        }
        while (dma_running()) tick();
        uint64_t rep = clk_n - c0;
        printf("replay: %zu events, %d errors\n", ev.size(), errors - e1);
        printf("  clocks: recorded %llu at one-clock memory, replayed %llu (x%.3f)\n",
               (unsigned long long)(ev.back().t - ev.front().t), (unsigned long long)rep,
               (double)rep / (ev.back().t - ev.front().t));
        printf("  work clocks: recorded %llu, replayed %llu (x%.3f)\n", (unsigned long long)work_rec,
               (unsigned long long)work_rep, work_rec ? (double)work_rep / work_rec : 0.0);
        if (frames > 0)
            printf("  work clocks a frame over %.2f frames: %.0f of 1128205 at 66.667 MHz (%.1f%%)\n",
                   frames, work_rep / frames, 100.0 * work_rep / frames / 1128205.0);
        printf("  fill: %llu, clocks to the acknowledge avg %.2f max %llu; histogram by 8:",
               (unsigned long long)fills, fills ? (double)fill_sum / fills : 0.0, (unsigned long long)fill_max);
        for (int i = 0; i < 8; i++) printf(" %llu", (unsigned long long)fill_hist[i]);
        printf("\n  DMA: %llu 32-byte blocks; the CPU waited %llu clocks for a running transfer\n",
               (unsigned long long)dma_lines, (unsigned long long)dma_wait);
        printf("  SDRAM busy %.1f%% of clk_mem cycles\n", 100.0 * (mem_busy_n - b0) / (mem_n - m0));
    }
    printf("%s: %d errors\n", errors ? "FAIL" : "PASS", errors);
    delete t;
    return errors ? 1 : 0;
}
