// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_midibridge's ST-224 side against a modelled DDR3 port and sound server:
//
//   scripts/run_verilator.sh bridge_tb [+stall=PERCENT]
//
// 400 ms at 66.667 MHz. A send frame every 1512 clocks (44.1 kHz) with left = its index and
// right = its complement, a MIDI byte every 320 us for the first 100 ms. The port takes a command
// when m_waitn is high (low on +stall percent of clocks) and answers a read 20 clocks later. The
// server reads the counts each millisecond and checks every new ring entry, and writes its
// heartbeat every 10 ms from 100 ms to 250 ms.
//
// Checks: every frame and byte reaches its ring in order, none lost; server_on rises within two
// beats of the heartbeat's first change and falls between ALIVE and ALIVE + 2 beats after its
// last; it changes only at a frame's edge.
#include "Vtb_bridge.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <string>
#include <unordered_map>

double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int stall = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("+stall=", 0) == 0) stall = atoi(a.c_str() + 7);
    }
    const uint32_t SHM = 0x3F200000, SRING = 2048, RING = 512;
    const uint64_t MS = 66667, BEAT = 666667, END = 400 * MS, HB_ON = 100 * MS, HB_OFF = 250 * MS;
    const int ALIVE = 5;
    std::unordered_map<uint32_t, uint64_t> mem;
    std::mt19937 rnd(7);
    auto *t = new Vtb_bridge;
    t->reset = 1; t->brd_reset = 0; t->held = 0; t->mute = 0; t->tx_v = 0; t->send_v = 0;
    t->m_waitn = 1; t->m_rvalid = 0; t->m_rdata = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 8; i++) tick();
    t->reset = 0;

    std::deque<std::pair<uint64_t, uint32_t>> rq;           // {clock due, data}
    uint32_t frames_sent = 0, bytes_sent = 0, frames_seen = 0, bytes_seen = 0, hb = 0;
    long bad = 0, edge_bad = 0;
    uint64_t hb_first = 0, hb_last = 0, rise = 0, fall = 0;
    bool on = false;
    for (uint64_t c = 0; c < END; c++) {
        // the model's inputs for this clock
        t->send_v = c % 1512 == 100;
        if (t->send_v) { t->send_l = frames_sent & 0xFFFF; t->send_r = ~frames_sent & 0xFFFF; frames_sent++; }
        t->tx_v = c < 100 * MS && c % 21333 == 50;
        if (t->tx_v) { t->tx_byte = bytes_sent & 0xFF; bytes_sent++; }
        t->m_waitn = (int)(rnd() % 100) >= stall;
        t->m_rvalid = 0;
        if (!rq.empty() && rq.front().first <= c) { t->m_rvalid = 1; t->m_rdata = rq.front().second; rq.pop_front(); }
        t->eval();
        if (t->m_waitn && t->m_write) mem[t->m_addr] = (uint64_t)t->m_wdata_hi << 32 | t->m_wdata;
        if (t->m_waitn && t->m_read) rq.push_back({c + 20, (uint32_t)mem[t->m_addr]});
        tick();

        // server_on moves only on the edge that takes a frame's strobe
        if (t->server_on != on) {
            if (!t->send_v) edge_bad++;
            on = t->server_on;
            (on ? rise : fall) = c;
        }

        // the server
        if (c >= HB_ON && c < HB_OFF && (c - HB_ON) % BEAT == 0) {
            mem[SHM + 0x30] = ++hb;
            if (!hb_first) hb_first = c;
            hb_last = c;
        }
        if (c % MS == 0) {
            uint32_t n = (uint32_t)mem[SHM + 0x28];
            if (n - frames_seen > SRING) { printf("frames overran: %u past %u\n", n, frames_seen); bad++; frames_seen = n - SRING; }
            for (; frames_seen != n; frames_seen++) {
                uint64_t e = mem[SHM + 0x2000 + 8 * (frames_seen % SRING)];
                uint32_t lr = (uint32_t)e, want = (frames_seen & 0xFFFF) | ((~frames_seen & 0xFFFF) << 16);
                if (lr != want && bad++ < 8) printf("frame %u: %08X, want %08X\n", frames_seen, lr, want);
            }
            uint32_t m = (uint32_t)mem[SHM + 0x10];
            for (; bytes_seen != m; bytes_seen++) {
                uint64_t e = mem[SHM + 0x1000 + 8 * (bytes_seen % RING)];
                if (((e >> 40) & 0xFF) != (bytes_seen & 0xFF) && bad++ < 8) printf("byte %u: %02X\n", bytes_seen, (unsigned)((e >> 40) & 0xFF));
            }
        }
    }
    uint32_t magic = (uint32_t)mem[SHM], ver = (uint32_t)(mem[SHM] >> 32);
    double beat = (double)BEAT;
    double r_beats = rise ? (rise - hb_first) / beat : -1, f_beats = fall ? (fall - hb_last) / beat : -1;
    printf("stall %d%%: magic %08X v%u; frames %u sent, %u seen; bytes %u sent, %u seen; %ld bad\n",
           stall, magic, ver, frames_sent, frames_seen, bytes_sent, bytes_seen, bad);
    printf("server_on: rise %.2f beats after the first heartbeat, fall %.2f after the last; %ld edges off a frame\n",
           r_beats, f_beats, edge_bad);
    // the frames of the last millisecond are not yet read
    bool ok = magic == 0x494D4246 && ver == 2 && bad == 0 && edge_bad == 0 &&
              frames_sent - frames_seen <= 45 && bytes_seen == bytes_sent &&
              r_beats >= 0 && r_beats <= 2.0 && f_beats >= ALIVE && f_beats <= ALIVE + 2.0;
    printf("%s\n", ok ? "PASS" : "FAIL");
    delete t;
    return ok ? 0 : 1;
}
