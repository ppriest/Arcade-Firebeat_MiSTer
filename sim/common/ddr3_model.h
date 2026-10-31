// SPDX-License-Identifier: GPL-3.0-or-later
//
// The DE10-nano's DDRAM port as hornet_ddr3 sees it, for C++ benches: 64-bit beats in a host array
// (the VRAM window, 32 MB from byte 0x30000000), DDRAM_BUSY high `busy` percent of the clocks, and a
// read's first beat `lat` clocks after the command, then a beat a clock, reads served in order. `gap`
// percent of the clocks a due beat is held back, so a burst's beats arrive with holes in them.
//
// Per clock, with the model's outputs set before the edge:
//     d.sample(t);          // before the rising edge: take the command or write beat on the port
//     (clock the model)
//     d.drive(t);           // after it: the inputs for the next edge

#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <vector>

struct Ddr3Model {
    static constexpr uint32_t BASE = 0x30000000u >> 3;     // the window's first beat
    static constexpr uint32_t BEATS = 0x2000000u >> 3;     // 32 MB
    std::vector<uint64_t> mem = std::vector<uint64_t>(BEATS, 0);
    // the state dump's area (rtl/board/fb_dump.sv), allocated at its first write; not saved
    static constexpr uint32_t DUMP = 0x34000000u >> 3, DUMP_BEATS = 0x2620000u >> 3;
    std::vector<uint64_t> dump;
    int lat = 20, busy = 10, gap = 0;
    uint64_t now = 0, rd_beats = 0, wr_beats = 0, busy_clocks = 0;
    struct Rd { uint32_t a; int n; uint64_t at; };
    std::deque<Rd> rq;
    uint32_t w_a = 0;
    int w_left = 0;
    uint32_t rng = 1;                     // BUSY's generator, saved with the model

    bool draw(int pct) {
        rng = rng * 1103515245u + 12345u;
        return (int)((rng >> 16) % 100) < pct;
    }
    bool busy_draw() { return draw(busy); }

    // a bench's save and restore: raw(pointer, bytes) writes or reads
    template <class F> void io(F raw, bool out) {
        raw(mem.data(), mem.size() * 8);
        raw(&now, sizeof now); raw(&rng, sizeof rng); raw(&w_a, sizeof w_a); raw(&w_left, sizeof w_left);
        uint32_t n = rq.size();
        raw(&n, sizeof n);
        if (!out) rq.resize(n);
        for (Rd &r : rq) raw(&r, sizeof r);
    }

    uint64_t &beat(uint32_t a) {
        if (a - DUMP < DUMP_BEATS) {
            if (dump.empty()) dump.assign(DUMP_BEATS, 0);
            return dump[a - DUMP];
        }
        uint32_t i = a - BASE;
        if (i >= BEATS) { fprintf(stderr, "ddr3: beat %08X outside VRAM\n", a); exit(1); }
        return mem[i];
    }

    template <class T> void sample(T *t) {
        if (t->DDRAM_BUSY) return;
        if (t->DDRAM_RD) {
            rq.push_back({(uint32_t)t->DDRAM_ADDR, (int)t->DDRAM_BURSTCNT, now + lat});
        }
        if (t->DDRAM_WE) {
            if (w_left == 0) { w_a = (uint32_t)t->DDRAM_ADDR; w_left = t->DDRAM_BURSTCNT; }
            uint64_t &m = beat(w_a);
            uint64_t d = t->DDRAM_DIN;
            for (int b = 0; b < 8; b++)
                if (t->DDRAM_BE >> b & 1) m = (m & ~(0xFFull << 8 * b)) | (d & 0xFFull << 8 * b);
            w_a++;
            w_left--;
            wr_beats++;
        }
    }

    template <class T> void drive(T *t) {
        now++;
        t->DDRAM_DOUT_READY = 0;
        if (!rq.empty() && rq.front().at <= now && !(gap && draw(gap))) {
            Rd &r = rq.front();
            t->DDRAM_DOUT = beat(r.a);
            t->DDRAM_DOUT_READY = 1;
            r.a++;
            rd_beats++;
            if (--r.n == 0) rq.pop_front();
        }
        t->DDRAM_BUSY = busy_draw();
        if (t->DDRAM_BUSY) busy_clocks++;
    }
};
