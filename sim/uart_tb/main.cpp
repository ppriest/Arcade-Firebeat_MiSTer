// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_ns16550 against MAME: each channel's accesses from a boot capture, in order.
//
//   grep -E "^(F [0-9]|[RW] 70000[0-9A-F]00 )" debug/kbm-boot/io.txt |
//       awk '/^F/{f=$2;next}{print f,$1,$2,$4}' > debug/kbm-boot/midi.txt
//   scripts/run_verilator.sh uart_tb +midi=debug/kbm-boot/midi.txt [+random=STEPS] [+nost]
//
// Every read is compared with MAME's, and the bytes sent with those written. The capture has
// frame resolution, so time is not replayed: frames with traffic are 45,000 clocks apart (two byte
// times) and the keyboard's bytes are sent just before MAME's first read that shows them. Waiting
// for those lets a byte being sent finish, so LSR's bit 6 is not compared for the rest of that frame.
//
// +random=STEPS: random accesses and received bytes, full FIFOs included, and a hash of every read,
// byte sent and interrupt update; two builds of the module with the same hash behaved alike.
// The state test reads and writes the FIFOs through the dump's port (+nost skips it).
#include "Vtb_uart.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <map>
#include <random>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static Vtb_uart* t;
static std::deque<int> rxq;            // line levels, a bit time each
static int bit_ce = 768, rx_acc = 0;
static std::vector<uint8_t> sent;
static uint64_t hash_v = 0xcbf29ce484222325ull;

static void mix(uint64_t v) { hash_v = (hash_v ^ v) * 0x100000001b3ull; }

// fb_midibridge's DDR3 (SHM 0x3F200000, the ring of 512 at +0x1000): each ring entry must be the
// next byte sent, its stamp not before the last, and the count written after its entry; a write
// is held off at random (waitn).
static std::map<uint32_t, uint64_t> ddr;
static std::mt19937 ddr_r(7);
static size_t br_entries = 0;
static uint32_t br_last_us = 0;
static int br_bad = 0;
static void br_check(uint32_t a, uint64_t d) {
    const uint32_t SHM = 0x3F200000;
    if (a >= SHM + 0x1000 && a < SHM + 0x2000) {
        const uint32_t slot = (a - SHM - 0x1000) / 8, us = (uint32_t)d;
        const uint8_t b = d >> 40 & 0xFF;
        if (slot != br_entries % 512 || br_entries >= sent.size() || b != sent[br_entries] ||
            (br_entries && us < br_last_us) || (d >> 48) || (d >> 32 & 0xFF)) {
            if (br_bad++ < 10) fprintf(stderr, "ring entry %zu: slot %u, %016llX, sent %zu\n", br_entries, slot,
                                       (unsigned long long)d, sent.size());
        }
        br_entries++; br_last_us = us;
    } else if (a == SHM + 0x10 && (uint32_t)d != br_entries) {
        if (br_bad++ < 10) fprintf(stderr, "count %u after %zu entries\n", (uint32_t)d, br_entries);
    }
}

static void tick() {
    t->clk = 0; t->eval();
    t->m_waitn = ddr_r() % 4 != 0;
    t->eval();
    if (t->m_write && t->m_waitn) {
        const uint64_t d = (uint64_t)t->m_wdata_hi << 32 | t->m_wdata;
        ddr[t->m_addr] = d;
        br_check(t->m_addr, d);
    }
    t->clk = 1; t->eval();
    if (t->tx_v) { sent.push_back(t->tx_byte); mix(0x100 | t->tx_byte); }
    if (t->int_upd) mix(0x200 | t->int_hi << 1 | t->int_q);
    rx_acc += 9;
    if (rx_acc >= 25 * bit_ce) {
        rx_acc -= 25 * bit_ce;
        if (rxq.empty()) t->rxd = 1;
        else { t->rxd = rxq.front(); rxq.pop_front(); }
    }
}
static void ticks(long n) { while (n-- > 0) tick(); }

static void send_byte(uint8_t b, bool bad_stop = false) {
    rxq.push_back(0);
    for (int i = 0; i < 8; i++) rxq.push_back(b >> i & 1);
    rxq.push_back(bad_stop ? 0 : 1);
    rxq.push_back(1);
}

static void reset() {
    t->rst = 1; t->req = 0; t->we = 0; t->rxd = 1; t->st_hold = 0; t->st_we = 0; t->held = 0;
    ticks(8);
    t->rst = 0; rxq.clear(); sent.clear(); rx_acc = 0; bit_ce = 768;
    ddr.clear(); br_entries = 0; br_last_us = 0;
    ticks(8);
}
static void wr(int a, uint8_t d) {
    t->req = 1; t->we = 1; t->addr = a; t->wdata = d; tick();
    t->req = 0; t->we = 0;
}
static uint8_t rd(int a) {
    t->req = 1; t->we = 0; t->addr = a; tick();
    t->req = 0;
    t->eval();
    uint8_t v = t->rdata;
    mix(0x400 | v);
    return v;
}

struct Acc { long f; bool w; int reg; uint8_t v; };

static int replay(const std::vector<Acc>& v, int ch) {
    reset();
    int bad = 0, nread = 0;
    long held = 0, frame = -1, waited = -1;
    bool dlab = false;
    std::vector<uint8_t> want;
    for (size_t i = 0; i < v.size(); i++) {
        const Acc& a = v[i];
        if (a.f != frame) { frame = a.f; ticks(45000); }
        ticks(20);
        if (a.w) {
            wr(a.reg, a.v);
            if (a.reg == 3) dlab = a.v >> 7;
            if (a.reg == 0 && !dlab) want.push_back(a.v);
            continue;
        }
        bool shows = (a.reg == 5 && (a.v & 1)) || (a.reg == 2 && !(a.v & 1) && (a.v & 4));
        if (shows && held == 0) {
            int n = 0;
            for (size_t j = i; j < v.size(); j++) {
                if (v[j].w) continue;
                if (v[j].reg == 5 && !(v[j].v & 1)) break;
                if (v[j].reg == 0) { send_byte(v[j].v); n++; }
            }
            held = n;
            waited = a.f;
            while (!rxq.empty()) tick();
            ticks(2 * 25 * bit_ce / 9 + 400);  // the stop bit, then the FIFO timeout
        }
        uint8_t q = rd(a.reg);
        nread++;
        if (a.reg == 0 && !dlab && held > 0) held--;
        uint8_t mask = (a.reg == 5 && waited == a.f) ? 0xBF : 0xFF;
        if (((q ^ a.v) & mask) && bad++ < 10)
            fprintf(stderr, "ch%d read %d frame %ld reg %d: MAME %02X RTL %02X\n", ch, nread, a.f, a.reg, a.v, q);
    }
    ticks(45000 * 8);
    if (sent != want) {
        size_t k = 0;
        while (k < sent.size() && k < want.size() && sent[k] == want[k]) k++;
        fprintf(stderr, "ch%d sent %zu bytes, the capture wrote %zu; the first to differ is %zu (%s)\n", ch,
                sent.size(), want.size(), k, k < sent.size() ? "a different byte" : "not sent");
        bad++;
    }
    const uint64_t magic = ddr.count(0x3F200000) ? ddr[0x3F200000] : 0;
    if (br_entries != sent.size() || magic != 0x00000001494D4246ull) {
        fprintf(stderr, "ch%d bridge: %zu entries for %zu bytes, magic %016llX\n", ch, br_entries, sent.size(),
                (unsigned long long)magic);
        br_bad++;
    }
    printf("ch%d: %d reads, %zu bytes sent, %d differ; bridge %zu entries, %d differ\n", ch, nread, want.size(), bad,
           br_entries, br_bad);
    bad += br_bad; br_bad = 0;
    return bad;
}

static void random_run(long steps) {
    reset();
    std::mt19937 r(1);
    wr(3, 0x83); wr(0, 2); wr(1, 0); wr(3, 0x03); wr(2, 0xC7); bit_ce = 32;
    long overruns = 0;
    for (long s = 0; s < steps; s++) {
        int pick = r() % 100;
        if (pick < 30) wr(0, r());
        else if (pick < 60) rd(0);
        else if (pick < 70) overruns += rd(5) >> 1 & 1;
        else if (pick < 80) rd(2);
        else if (pick < 85) wr(1, r() & 15);
        else if (pick < 86) { if (r() % 16 == 0) wr(2, r()); }
        else if (pick < 88) wr(3, 3);
        else if (pick < 89) wr(5, r());
        else if (pick < 90) rd(1 + r() % 4);
        else if (rxq.size() < 400) send_byte(r(), r() % 16 == 0);
        ticks(r() % 8 == 0 ? r() % 4000 : r() % 16);
    }
    printf("random: %ld steps, %zu bytes sent, %ld overruns seen, hash %016llX\n", steps, sent.size(), overruns, (unsigned long long)hash_v);
}

static int st_read(int a) {
    t->st_a = a; t->eval();
    return t->st_d;
}

static int state_test() {
    reset();
    int bad = 0;
    wr(3, 0x83); wr(0, 2); wr(1, 0); wr(3, 0x03); wr(2, 0x07); bit_ce = 32;
    for (int i = 0; i < 8; i++) wr(0, 0xA0 + i);   // the first goes straight to the shift register
    for (int i = 0; i < 4; i++) send_byte(0x50 + i);
    while (!rxq.empty()) tick();
    ticks(800);
    size_t before = sent.size();
    t->st_hold = 1;
    for (int i = 0; i < 4; i++) if (st_read(0x40 + i) != 0x50 + i) { bad++; fprintf(stderr, "rfifo[%d] reads %02X\n", i, st_read(0x40 + i)); }
    for (int i = 0; i < 8; i++) if (st_read(0x50 + i) != 0xA0 + i) { bad++; fprintf(stderr, "tfifo[%d] reads %02X\n", i, st_read(0x50 + i)); }
    ticks(5000);
    if (sent.size() != before) { bad++; fprintf(stderr, "the transmitter ran during the hold\n"); }
    t->st_a = 0x41; t->st_wd = 0x77; t->st_we = 1; tick(); t->st_we = 0;
    t->st_hold = 0;
    t->eval();
    if (rd(0) != 0x50) bad++;
    if (rd(0) != 0x77) { bad++; fprintf(stderr, "a written rfifo word did not come back\n"); }
    ticks(200000);
    std::vector<uint8_t> want;
    for (int i = 0; i < 8; i++) want.push_back(0xA0 + i);
    if (sent != want) { bad++; fprintf(stderr, "the hold changed the bytes sent\n"); }
    printf("state: %d differ\n", bad);
    return bad;
}

// Sixteen bytes behind a busy shift register fill the FIFO; all seventeen must go out and THRE
// come back (kbm writes this on the board; 4-bit indices read the full FIFO as empty).
static int full_test() {
    reset();
    int bad = 0;
    wr(3, 0x83); wr(0, 2); wr(1, 0); wr(3, 0x03); wr(2, 0x07); bit_ce = 32;
    std::vector<uint8_t> want;
    for (int i = 0; i < 17; i++) { wr(0, 0x30 + i); want.push_back(0x30 + i); }
    ticks(200000);
    uint8_t l = rd(5);
    if (sent != want || l != 0x60) { bad++; fprintf(stderr, "full FIFO: %zu of 17 sent, LSR %02X\n", sent.size(), l); }
    printf("full: %d differ\n", bad);
    return bad;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_uart;
    std::string f;
    long steps = 0;
    bool nost = false;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        if (s.rfind("+midi=", 0) == 0) f = s.substr(6);
        if (s.rfind("+random=", 0) == 0) steps = atol(s.c_str() + 8);
        if (s == "+nost") nost = true;
    }
    int bad = 0;
    std::vector<Acc> ch[2];
    std::ifstream in(f);
    long fr; std::string rw; uint32_t ad, d;
    while (in >> std::dec >> fr >> rw >> std::hex >> ad >> d)
        ch[ad >> 11 & 1].push_back({fr, rw == "W", (int)(ad >> 8 & 7), (uint8_t)(d >> 24)});
    if (!f.empty()) for (int c = 0; c < 2; c++) bad += replay(ch[c], c);
    if (steps) random_run(steps);
    if (!nost) bad += state_test();
    bad += full_test();
    delete t;
    return bad ? 1 : 0;
}
