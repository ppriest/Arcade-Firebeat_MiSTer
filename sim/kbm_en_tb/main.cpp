// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_kbm_en against a disc (chdman extractcd's .bin, MODE1/2352): the volume descriptor and the
// root directory's frames go through it as fb_cd_slot writes them, and the directory read back is parsed.
//
//   scripts/run_verilator.sh kbm_en_tb +bin=<disc.bin> [+expect=en|same]
//
// en: with the option on, each Japanese screen's record must carry its X file's extent and size,
// both byte orders, and nothing else in the directory may change; with it off the directory is unchanged.
// same: a disc not in the table (2nd/3rd Mix) is unchanged with the option on.
#include "Vtb_kbm_en.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static Vtb_kbm_en* t;
static FILE* bin;

static std::vector<uint8_t> frame_user(uint32_t n) {
    std::vector<uint8_t> d(2048);
    fseek(bin, long(n) * 2352 + 16, SEEK_SET);
    if (fread(d.data(), 1, 2048, bin) != 2048) d.assign(2048, 0);
    return d;
}

static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }

// one frame through the module; returns what reaches the drive's buffer
static std::vector<uint8_t> feed(uint32_t n) {
    std::vector<uint8_t> d = frame_user(n), q(2048);
    t->rq_lba = n;
    for (int w = 0; w < 1024; w++) {
        t->bw_we = 1; t->bw_a = w; t->bw_d = d[2 * w] | d[2 * w + 1] << 8;
        t->clk = 0; t->eval();
        q[2 * w] = t->bw_q & 0xFF; q[2 * w + 1] = t->bw_q >> 8;
        t->clk = 1; t->eval();
    }
    t->bw_we = 0; tick();
    return q;
}

static uint32_t le32(const uint8_t* p) { return p[0] | p[1] << 8 | p[2] << 16 | uint32_t(p[3]) << 24; }
static uint32_t be32(const uint8_t* p) { return p[3] | p[2] << 8 | p[1] << 16 | uint32_t(p[0]) << 24; }

struct Rec { uint32_t lba_le, lba_be, size_le, size_be; };

static std::map<std::string, Rec> records(const std::vector<uint8_t>& d) {
    std::map<std::string, Rec> m;
    for (size_t f = 0; f < d.size(); f += 2048)
        for (size_t i = f; i < f + 2048 && d[i];) {
            std::string n(reinterpret_cast<const char*>(&d[i + 33]), d[i + 32]);
            n = n.substr(0, n.find(';'));
            m[n] = {le32(&d[i + 2]), be32(&d[i + 6]), le32(&d[i + 10]), be32(&d[i + 14])};
            i += d[i];
        }
    return m;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string path, expect = "en";
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        if (s.rfind("+bin=", 0) == 0) path = s.substr(5);
        if (s.rfind("+expect=", 0) == 0) expect = s.substr(8);
    }
    bin = fopen(path.c_str(), "rb");
    if (!bin) { fprintf(stderr, "cannot open %s\n", path.c_str()); return 2; }
    t = new Vtb_kbm_en;
    const std::vector<uint8_t> pvd = frame_user(16);
    const uint32_t root = le32(&pvd[156 + 2]);
    const uint32_t nroot = (le32(&pvd[156 + 10]) + 2047) / 2048;
    std::vector<uint8_t> orig;
    for (uint32_t k = 0; k < nroot; k++) { auto f = frame_user(root + k); orig.insert(orig.end(), f.begin(), f.end()); }
    int bad = 0;
    for (int on = 0; on < 2; on++) {
        t->reset = 1; t->en = on; tick(); t->reset = 0; tick();
        feed(16);
        std::vector<uint8_t> got;
        for (uint32_t k = 0; k < nroot; k++) { auto f = feed(root + k); got.insert(got.end(), f.begin(), f.end()); }
        std::map<std::string, Rec> o = records(orig), g = records(got);
        const char* pairs[6][2] = {{"DEMO.ZCC", "XDEMO.ZCC"}, {"ENTRY_L.ZCC", "XENTRY_L.ZCC"},
                                   {"MAIN_L.ZCC", "XMAIN_L.ZCC"}, {"MAIN_R.ZCC", "XMAIN_R.ZCC"},
                                   {"MU_SEL.ZCC", "XMU_SEL.ZCC"}, {"MU_SEL_R.ZCC", "XMU_SELR.ZCC"}};
        int changed = 0;
        for (size_t b = 0; b < got.size(); b++) changed += got[b] != orig[b];
        if (on && expect == "en") {
            for (auto& p : pairs) {
                const Rec r = g[p[0]], x = o[p[1]];
                if (memcmp(&r, &x, sizeof r)) { bad++; fprintf(stderr, "%s: %u/%u %u/%u, want %u %u\n", p[0], r.lba_le, r.lba_be, r.size_le, r.size_be, x.lba_le, x.size_le); }
            }
            for (auto& [n, r] : g) {
                bool target = false;
                for (auto& p : pairs) target |= n == p[0];
                if (!target && memcmp(&r, &o[n], sizeof r)) { bad++; fprintf(stderr, "%s changed\n", n.c_str()); }
            }
            printf("option on: %d bytes changed, 6 records checked\n", changed);
        } else {
            if (changed) { bad++; fprintf(stderr, "option %s: %d bytes changed\n", on ? "on" : "off", changed); }
            printf("option %s: %d bytes changed\n", on ? "on" : "off", changed);
        }
    }
    printf("%s: %s\n", path.c_str(), bad ? "FAIL" : "pass");
    delete t;
    return bad ? 1 : 0;
}
