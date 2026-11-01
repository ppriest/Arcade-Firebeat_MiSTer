// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_cd_slot's CD audio: serves +bin=FILE (2,352-byte frames, with an FBTC block after them) through
// hps_io's handshake, plays +frames=N frames from +lba=L at 44.1 kHz with vol0 0xFF and vol1 0x80,
// and checks every output sample against the file's (sample * vol >>> 9). A data read (+rq_every=K
// frames) runs alongside to check the two kinds of request share the slot. Samples before the first
// frame arrives are 0 and counted; any later mismatch fails.
//
//     scripts/run_verilator.sh cdaudio_tb +bin=debug/cdimages/gc977jaa02.bin +lba=6691 +frames=150
#include "Vtb_cdaudio.h"
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

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string bp = arg("bin", "debug/cdimages/gc977jaa02.bin");
    long lba0 = atol(arg("lba", "6691").c_str()), frames = atol(arg("frames", "150").c_str());
    long rq_every = atol(arg("rq_every", "7").c_str());
    FILE *f = fopen(bp.c_str(), "rb");
    if (!f) { printf("FAIL %s\n", bp.c_str()); return 1; }
    fseek(f, 0, SEEK_END);
    uint64_t bsize = ftell(f);
    uint64_t isize = (bsize + 511) / 512 * 512 + 1024;
    auto byte_at = [&](uint64_t a) -> int {
        static uint64_t base = ~0ull; static uint8_t blk[65536];
        if (a >= bsize) {
            uint64_t t = a - (bsize + 511) / 512 * 512;     // the TOC blocks
            const uint8_t toc[16] = {'F','B','T','C', 1, 1, 0, 0,  0,0,0,0, 1,0,0,0};
            return t < 16 ? toc[t] : 0;
        }
        if (a - base >= sizeof blk) { base = a & ~0xffffull; fseek(f, base, SEEK_SET); fread(blk, 1, sizeof blk, f); }
        return blk[a - base];
    };

    Vtb_cdaudio *t = new Vtb_cdaudio;
    // the server: sd_ack 20 clocks after sd_rd, a word every 4 clocks
    int sd_wait = 0; long sd_w = -1, sd_n = 0; int sd_gap = 0;
    auto clk = [&]() {
        t->sd_buff_wr = 0;
        if (sd_w < 0) {
            if (t->sd_rd && ++sd_wait >= 20) { t->sd_ack = 1; sd_w = 0; sd_n = (t->sd_blk_cnt + 1) * 256; sd_wait = 0; }
        } else if (sd_w < sd_n) {
            if (++sd_gap == 4) {
                sd_gap = 0;
                uint64_t a = (uint64_t)t->sd_lba * 512 + sd_w * 2;
                t->sd_buff_dout = byte_at(a) | (byte_at(a + 1) << 8);
                t->sd_buff_wr = 1; sd_w++;
            }
        } else { t->sd_ack = 0; sd_w = -1; }
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
    };
    t->reset = 1; t->mounted = 0; t->play_on = 0; t->play_tick = 0; t->rq = 0;
    t->vol0 = 0xff; t->vol1 = 0x80;
    for (int i = 0; i < 8; i++) clk();
    t->reset = 0; t->img_size = isize; t->mounted = 1; clk(); t->mounted = 0;
    for (int i = 0; i < 200000 && !t->have_disc; i++) clk();
    if (!t->have_disc) { printf("FAIL no disc\n"); return 1; }

    long acc = 0, zeros = 0, good = 0, bad = 0, rqs = 0, rq_ok = 0;
    bool started = false;
    t->play_on = 1;
    for (long fr = 0; fr < frames; fr++) {
        long lba = lba0 + fr;
        if (rq_every && fr % rq_every == 3) { t->rq = 1; t->rq_lba = 100 + fr; rqs++; }
        for (int s = 0; s < 588; s++) {
            t->play_lba = lba; t->play_smp = s; t->play_tick = 1;
            clk(); t->play_tick = 0; t->rq = 0;
            // 1,511.6 clocks a sample at 66.667 MHz
            acc += 1998677; long n = acc / 1323; acc -= n * 1323;
            for (long i = 1; i < n; i++) { clk(); if (t->rq_done) rq_ok++; }
            int16_t l = t->cd_l, r = t->cd_r;
            uint64_t a = (uint64_t)lba * 2352 + s * 4;
            int16_t sl = (int16_t)(byte_at(a) | (byte_at(a + 1) << 8)), sr = (int16_t)(byte_at(a + 2) | (byte_at(a + 3) << 8));
            int16_t el = (int16_t)(((int32_t)sl * 0xff) >> 9), er = (int16_t)(((int32_t)sr * 0x80) >> 9);
            if (l == el && r == er && (el || er)) { started = true; good++; }
            else if (l == el && r == er) good++;
            else if (!started && l == 0 && r == 0) zeros++;
            else { if (bad < 10) printf("MISMATCH lba %ld smp %d got %d %d want %d %d\n", lba, s, l, r, el, er); bad++; }
        }
    }
    printf("%ld samples: %ld match, %ld silent before the first frame, %ld mismatches; %ld data reads, %ld done\n",
           frames * 588, good, zeros, bad, rqs, rq_ok);
    delete t;
    return (bad || rq_ok != rqs) ? 1 : 0;
}
