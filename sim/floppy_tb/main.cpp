// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_floppy against MAME: sim/floppy_tb/fdc_script.py's script of what bm3 did to its FDC, played
// at the controller's own pace (each command and data byte when the MSR asks for it), every read
// compared, with an hps_io drive modelled on an image file. At the end the image is compared with
// the one MAME left.
//
//     python sim/floppy_tb/fdc_script.py debug/bm3-fdc1/fdc.txt debug/bm3-fdc1/script.txt
//     scripts/run_verilator.sh floppy_tb +script=debug/bm3-fdc1/script.txt
//         +img=debug/bm3-fdc-blank/blank.img +want=debug/bm3-fdc-disk/saved1.img
//
// +img=none leaves the drive empty (debug/bm3-fdc-nodisk: bm3's boot accesses with no disk).
#include "Vtb_floppy.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

double sc_time_stamp()
{
    return 0;
}

static Vtb_floppy *t;
static uint64_t cyc = 0;
static std::vector<uint8_t> img;
static int fails = 0;
static int checks = 0;
static int irqs = 0;

// the hps_io drive as Main serves the slot: (sd_blk_cnt + 1) blocks of 512 bytes (BLKSZ 2) at
// sd_lba * 512 (user_io.cpp), sd_blk_cnt 0 here (Firebeat.sv); a request is answered SD_LAT clocks
// later, a word every WORD_GAP clocks
static const int XFER_WORDS = 256;
static int SD_LAT = 2000; // +sdlat= overrides: Main on the board answers in milliseconds
static const int WORD_GAP = 4;
static int sd_state = 0;
static int sd_wait = 0;
static int sd_word = 0;
static bool sd_writing = false;

static std::string arg(const char *n, const char *d)
{
    const char *v = Verilated::commandArgsPlusMatch(n);
    std::string s = v && *v ? v : "";
    std::string k = std::string("+") + n + "=";
    if (s.rfind(k, 0) == 0) {
        return s.substr(k.size());
    }
    return d;
}

static std::vector<uint8_t> load(const std::string &p)
{
    std::ifstream f(p, std::ios::binary);
    if (!f) {
        printf("FAIL open %s\n", p.c_str());
        exit(1);
    }
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static void sd_step()
{
    t->sd_buff_wr = 0;
    switch (sd_state) {
    case 0:
        if (t->sd_rd || t->sd_wr) {
            sd_writing = t->sd_wr;
            sd_wait = SD_LAT;
            sd_state = 1;
        }
        break;
    case 1:
        sd_wait--;
        if (sd_wait == 0) {
            t->sd_ack = 1;
            sd_word = 0;
            t->sd_buff_addr = 0;
            sd_wait = WORD_GAP;
            sd_state = 2;
        }
        break;
    case 2:
        sd_wait--;
        if (sd_wait == 0) {
            // as hps_io: the word at sd_buff_addr written (with sd_buff_wr) or read (sd_buff_din, the
            // address set WORD_GAP clocks before), then the address moves on
            uint32_t base = t->sd_lba * 512 + sd_word * 2;
            t->sd_buff_addr = sd_word;
            if (sd_writing) {
                uint16_t w = t->sd_buff_din;
                img[base] = w & 0xFF;
                img[base + 1] = w >> 8;
            } else {
                t->sd_buff_dout = img[base] | (img[base + 1] << 8);
                t->sd_buff_wr = 1;
            }
            sd_word++;
            sd_state = (sd_word == XFER_WORDS) ? 4 : 5;
            sd_wait = WORD_GAP;
        }
        break;
    case 4:
        t->sd_ack = 0;
        sd_state = 0;
        break;
    case 5:
        t->sd_buff_addr = sd_word;
        sd_state = 2;
        break;
    }
}

static void tick()
{
    t->clk = 0;
    t->eval();
    t->clk = 1;
    t->eval();
    cyc++;
    if (t->irq) {
        irqs++;
    }
    sd_step();
}

// one bus access, as fb_board makes it: req for a clock, the read's data taken in the clock after
// (B_LANE's D_FDC), so as the req clock's edge leaves it
static uint8_t access(bool we, int port, uint8_t d)
{
    t->req = 1;
    t->we = we;
    t->port = port;
    t->wdata = d;
    tick();
    uint8_t q = t->rdata;
    t->req = 0;
    t->we = 0;
    tick();
    for (int i = 0; i < 6; i++) {
        tick();
    }
    return q;
}

static void check(const char *what, int i, int got, int want)
{
    checks++;
    if (got != want) {
        fails++;
        if (fails <= 20) {
            printf("  %s[%d]: %02X, MAME %02X (clock %llu)\n", what, i, got, want, (unsigned long long)cyc);
        }
    }
}

// the MSR until it shows `want` under `mask`: its value, or -1
static int wait_msr(int mask, int want)
{
    for (int n = 0; n < 200000; n++) {
        int m = access(false, 4, 0);
        if ((m & mask) == want) {
            return m;
        }
    }
    return -1;
}

// a script byte, "bb" or "bb/mm" (mm: the MSR MAME read last before it, -1 if none)
static bool token(std::istringstream &s, int &b, int &m)
{
    std::string t;
    if (!(s >> t)) {
        return false;
    }
    b = (int)strtol(t.c_str(), nullptr, 16);
    size_t k = t.find('/');
    m = (k == std::string::npos) ? -1 : (int)strtol(t.c_str() + k + 1, nullptr, 16);
    return true;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    t = new Vtb_floppy;
    std::string img_path = arg("img", "debug/bm3-fdc-blank/blank.img");
    SD_LAT = std::stoi(arg("sdlat", "2000"));
    bool no_disk = img_path == "none";   // the drive empty: nothing mounted
    if (!no_disk) {
        img = load(img_path);
    }
    std::string want_img = arg("want", "");
    std::ifstream sc(arg("script", "debug/bm3-fdc1/script.txt"));
    if (!sc) {
        printf("FAIL no script\n");
        return 1;
    }

    t->reset = 1;
    t->img_size = img.size();
    t->img_readonly = 0;
    for (int i = 0; i < 20; i++) {
        tick();
    }
    t->img_mounted = !no_disk;
    tick();
    t->img_mounted = 0;
    for (int i = 0; i < 40; i++) {
        tick();
    }
    t->reset = 0;
    for (int i = 0; i < 20; i++) {
        tick();
    }

    std::string line;
    int ln = 0;
    while (std::getline(sc, line)) {
        ln++;
        std::istringstream s(line);
        std::string op;
        s >> op;
        if (op == "W") {
            int p;
            int d;
            s >> p >> std::hex >> d;
            access(true, p, d);
        } else if (op == "R") {
            int p;
            int d;
            s >> p >> std::hex >> d;
            check("R", p, access(false, p, 0), d);
        } else if (op == "C") {
            int b;
            int m;
            int i = 0;
            while (token(s, b, m)) {
                int msr = wait_msr(0xC0, 0x80);
                if (msr < 0) {
                    printf("  line %d: no request for command byte %d\n", ln, i);
                    fails++;
                    break;
                }
                if (m >= 0) {
                    check("MSR", ln, msr, m);
                }
                access(true, 5, b);
                i++;
            }
        } else if (op == "I") {
            int before = irqs;
            for (int n = 0; n < 2000000 && irqs == before; n++) {
                tick();
            }
            if (irqs == before) {
                printf("  line %d: no interrupt\n", ln);
                fails++;
            }
        } else if (op == "D" || op == "E" || op == "S") {
            int n;
            s >> std::dec >> n;
            int dio = (op == "E") ? 0x00 : 0x40;
            int ndm = (op == "S") ? 0x00 : 0x20;
            for (int i = 0; i < n; i++) {
                int b;
                int m;
                token(s, b, m);
                int msr = wait_msr(0xE0, 0x80 | dio | ndm);
                if (msr >= 0 && m >= 0) {
                    check("MSR", ln, msr, m);
                }
                if (msr < 0) {
                    printf("  line %d: %s byte %d of %d not offered (MSR %02X)\n", ln, op.c_str(), i, n, access(false, 4, 0));
                    fails++;
                    break;
                }
                if (op == "E") {
                    access(true, 5, b);
                } else {
                    check(op.c_str(), i, access(false, 5, 0), b);
                }
            }
        }
    }
    printf("%d lines, %d checks, %d differ, %d interrupts, %llu clocks\n", ln, checks, fails, irqs, (unsigned long long)cyc);
    if (!want_img.empty()) {
        auto w = load(want_img);
        int d = 0;
        for (size_t i = 0; i < w.size() && i < img.size(); i++) {
            if (w[i] != img[i]) {
                if (d < 5) {
                    printf("  image byte %zu: %02X, MAME %02X\n", i, img[i], w[i]);
                }
                d++;
            }
        }
        printf("image: %d bytes differ from %s\n", d, want_img.c_str());
        if (d) {
            fails++;
        }
    }
    printf(fails ? "FAIL\n" : "PASS\n");
    delete t;
    return fails ? 1 : 0;
}
