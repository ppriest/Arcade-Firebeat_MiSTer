// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/board/fb_board.sv from power-on, against MAME's boot (scripts/mame_boot_capture.py):
//
//   scripts/run_verilator.sh boot_tb +boot=debug/ppp11-boot +frames=N [+bios=FILE] [+lat=N]
//       [+cd0=BIN +cue0=CUE +cd1=BIN +cue1=CUE] [+trace=FROM] [+iolog=FROM] [+save=FRAME] [+restore=FILE]
//       [+events=FRAME:MASK:LEN,...] [+reset_at=CLOCK] [+sdwait=MIN[:MAX]] [+dump=FRAME] [+state=FILE]
//
// Without <boot>/nvram_start the board starts blank, as MAME without NVRAM files: the flash 0xFF,
// the RTC in its reset state (MAME's nvram_default).
// +events: IN0 bits (hex mask, active low) held for LEN frames from MAME frame FRAME (as
// scripts/mame_boot_capture.py --events). The board's frames run behind MAME's (its RAM test and
// disc reads take longer), so the events are placed from an anchor: MAME's last ATA register write
// before the first event. When the board makes that write, an event at MAME frame F fires
// F - (the anchor's MAME frame) frames later. With +state there is no anchor: FRAME counts from the
// run's first frame.
//
// +reset_at=CLOCK: the board reset for 16 clocks at the first clock from CLOCK with no SDRAM or slot
// request open, as the OSD's "Reset" after mounting the discs; they must stay mounted.
// +sdwait=MIN[:MAX]: clocks from a slot request to its first data, uniform per request (default
// 33000). The board's CHD reads take 2-43 ms to the first word (HARDWARE_NOTES, the slot table).
// +save=FRAME writes the model and the bench's state to <boot>/save_<FRAME>.bin at that frame;
// +restore=FILE resumes from one (the same build of the model only).
// +dump=FRAME runs the board's state dump (rtl/board/fb_dump.sv) at that frame, writes
// <boot>/dump_<FRAME>.bin as the HPS fetches it (DDR3 0x34000000-0x3661FFFF, then VRAM
// 0x30000000-0x31FFFFFF), checks its SDRAM block against the bench's SDRAM, and releases the board.
// +state=FILE starts the board from such a file instead of power-on: SDRAM, VRAM and the register
// block loaded, the CPU from its first instruction there. MAME's streams do not apply then. The
// devices' blocks are written once both slots have served their mount (whose media change would
// overwrite the drives'), and the CPU is held until then.
//
// The board starts as the core loads it: the BIOS and the dongle image (the .mra), the flash chips
// and the RTC from the NVRAM files the MAME run started from (<boot>/nvram_start). The discs come
// through hps_io image slots served here: each .bin's frames, then its TOC block (fb_cd_slot's
// format, from the .cue), with an HPS-like delay before each request's data. vblank follows
// control_w bit 0 as MAME's screen does: 640x480 of 800x525 at 25.175 MHz until it is set, then
// the 685x416 frame at 16.6666 MHz.
//
// The comparison: MAME's io.txt and the board's bus monitor split into per-device streams, each
// compared in order. Runs of identical reads count once; reads that poll a status (ATA status and
// alternate status, the serial port's line status, the GCU's status, the RTC's clock registers)
// are not compared, since the board's timing is not MAME's. The first difference in each stream
// is reported with MAME's frame and the board's.

#include "Vtb_boot.h"
#include "verilated.h"
#include "../common/ddr3_model.h"
#include <algorithm>
#include <fcntl.h>
#include "verilated_save.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <type_traits>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> load(const std::string &p, size_t size, bool must = true) {
    std::vector<uint8_t> v(size, 0);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { if (must) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); } v.clear(); return v; }
    size_t n = fread(v.data(), 1, size, f);
    fclose(f);
    v.resize(n);
    return v;
}
static uint32_t be32(const uint8_t *m) { return (uint32_t)m[0] << 24 | (uint32_t)m[1] << 16 | (uint32_t)m[2] << 8 | m[3]; }

// ---------------------------------------------------------------------------- the device streams
struct Acc { char rw; uint32_t a, m, d; long frame; };

// the stream an access belongs to, or "" if it is not compared
static std::string stream_of(const Acc &x) {
    uint32_t a = x.a;
    bool r = x.rw == 'R';
    if ((a & 0xfffffff0) == 0x40000000) return (r && a == 0x40000000 && (x.m & 0xff000000)) ? "" : (r ? "SPU_R" : "SPU_W");
    if ((a & 0xffffff00) == 0x7e800000) {
        if (r && a == 0x7e800078) return "";
        if (r) return a >= 0x7e800080 ? "GCU_VRAM_R" : "GCU_R";
        // a stream per register (per half of 0x10): the vblank handler's writes interleave with the
        // main code's at the board's timing, not MAME's
        char k[24];
        if (a == 0x7e800010) snprintf(k, sizeof k, "GCU_W10%s", (x.m & 0xffff0000) ? "H" : "L");
        else snprintf(k, sizeof k, "GCU_W%02X", a & 0xff);
        return k;
    }
    if ((a & 0xfffffff0) == 0x7fe00000 || (a & 0xfffffff0) == 0x7fe80000) {
        bool cs1 = (a & 0xfffffff0) == 0x7fe80000;
        if (r && ((!cs1 && a == 0x7fe0000c && (x.m & 0x0000ffff)) || (cs1 && a == 0x7fe8000c && (x.m & 0xffff0000)))) return "";
        if (r && !cs1 && a == 0x7fe00000 && (x.m & 0xffff0000)) return "ATA_DATA";
        return r ? "ATA_R" : "ATA_W";
    }
    if ((a & 0xffffffc0) == 0x7e000000) return r ? "" : "RTC_W";
    if ((a & 0xffffffc0) == 0x7e000100) return r ? "RTC_XR" : "RTC_W";
    if (a >= 0x7d400000 && a < 0x7dc00000) return r ? "FLASH_R" : "FLASH_W";
    if ((a & 0xfffffffe) == 0x7d000400) return r ? "YMZ_R" : "YMZ_W";
    if ((a & 0xfffffff0) == 0x7dc00000) return std::string(r ? "DUART_R" : "DUART_W") + ((a & 8) ? "1" : "0");
    if (a >= 0x7d000000 && a < 0x7d001000) {   // a stream per register, as the GCU's
        char k[24];
        snprintf(k, sizeof k, "IO_%c%03X", r ? 'R' : 'W', a & 0xffc);
        return k;
    }
    if ((a & 0xffff0000) == 0x70000000) return r ? "XIRQ_R" : "XIRQ_W";
    return r ? "OTHER_R" : "OTHER_W";
}

struct Stream {
    std::vector<Acc> mame;
    size_t pos = 0;                     // the next MAME entry to compare
    Acc last_rtl{}; bool have_last = false;
    long compared = 0;
    bool diverged = false;
};

int main(int argc, char **argv) {
#ifdef _WIN32
    // VerilatedSave/VerilatedRestore open without O_BINARY: under MinGW the save would be written
    // and read in text mode, newlines translated
    _fmode = _O_BINARY;
#endif
    Verilated::commandArgs(argc, argv);
    const char *s;
    auto arg = [&](const char *k, const char *def) -> std::string {
        std::string key = std::string(k) + "=";
        const char *v = Verilated::commandArgsPlusMatch(key.c_str());
        return (v && *v) ? std::string(v + key.size() + 1) : std::string(def);
    };
    std::string bdir = arg("boot", "debug/ppp11-boot") + "/";
    long frames_max = atol(arg("frames", "600").c_str());
    int lat = atoi(arg("lat", "12").c_str());
    long trace_from = atol(arg("trace", "-1").c_str());
    // +regpc=PC[,PC...] or +regpc=LO-HI: from frame +regfrom (default +trace's), the GPRs, CR and LR
    // printed as each of these PCs executes
    long reg_from = atol(arg("regfrom", std::to_string(trace_from).c_str()).c_str());
    uint32_t reg_lo = 1, reg_hi = 0;
    std::vector<uint32_t> regpc;
    for (std::string l = arg("regpc", ""); !l.empty();) {
        size_t c = l.find(',');
        size_t d = l.find('-');
        if (d != std::string::npos && d < c) { reg_lo = strtoul(l.substr(0, d).c_str(), nullptr, 16); reg_hi = strtoul(l.substr(d + 1, c - d - 1).c_str(), nullptr, 16); }
        else regpc.push_back(strtoul(l.substr(0, c).c_str(), nullptr, 16));
        l = c == std::string::npos ? "" : l.substr(c + 1);
    }
    long iolog_from = atol(arg("iolog", "-1").c_str());   // device accesses from this frame, but the GCU's, the inputs' and the sensors'
    long save_at = atol(arg("save", "-1").c_str());
    long long reset_at = atoll(arg("reset_at", "-1").c_str());
    int reset_left = 0;
    // +sdwait=MIN[:MAX]: clocks from a slot request to its data, uniform in [MIN, MAX] per request
    int sdw_min = 33000, sdw_max = 33000;
    uint32_t sdw_rng = 1;
    {
        std::string w = arg("sdwait", "");
        if (!w.empty()) {
            sdw_min = sdw_max = atoi(w.c_str());
            size_t c = w.find(':');
            if (c != std::string::npos) sdw_max = atoi(w.c_str() + c + 1);
        }
    }
    auto sd_wait = [&]() {
        sdw_rng = sdw_rng * 1103515245u + 12345u;
        return sdw_min + (int)((sdw_rng >> 8) % (uint32_t)(sdw_max - sdw_min + 1));
    };
    std::string restore_f = arg("restore", "");
    long dump_at = atol(arg("dump", "-1").c_str());
    std::string state_f = arg("state", "");
    std::vector<uint8_t> stf;
    if (!state_f.empty()) {
        stf = load(state_f, 0x2620000 + 0x2000000);
        if (stf.size() != 0x2620000 + 0x2000000 || stf[0] != 0x44 || stf[1] != 0x53 || stf[2] != 0x42 || stf[3] != 0x46) {
            fprintf(stderr, "%s: not a state dump\n", state_f.c_str()); return 1;
        }
    }
    // a dump file's little-endian word at byte offset o
    auto stw = [&](uint32_t o) { return (uint32_t)stf[o] | stf[o + 1] << 8 | stf[o + 2] << 16 | (uint32_t)stf[o + 3] << 24; };
    std::string bios_f = arg("bios", "debug/ppp11-win21357/bios.bin");
    std::string cdf[2] = {arg("cd0", "debug/cdimages/gc977jaa01.bin"), arg("cd1", "debug/cdimages/gc977jaa02.bin")};
    std::string cuef[2] = {arg("cue0", "debug/cdimages/gc977jaa01.cue"), arg("cue1", "debug/cdimages/gc977jaa02.cue")};

    // SDRAM: work RAM (zero), the flash chips, the BIOS
    std::vector<uint8_t> sd(0x4000000, 0);
    const char *fl[3] = {"flash_main", "flash_snd1", "flash_snd2"};
    bool nv_ok = true;
    for (int k = 0; k < 3; k++) {
        auto f = load(bdir + "nvram_start/" + fl[k], 0x200000, false);
        if (f.empty()) { nv_ok = false; f.assign(0x200000, 0xff); }
        memcpy(sd.data() + 0x2000000 + 0x200000 * k, f.data(), f.size());
    }
    { auto b = load(bios_f, 0x80000); memcpy(sd.data() + 0x2800000, b.data(), b.size()); }
    auto rtcnv = load(bdir + "nvram_start/rtc", 4152, false);
    if (!stf.empty()) rtcnv.resize(4152);
    if (!stf.empty()) for (int i = 0; i < 4152; i++) rtcnv[i] = stf[0x1000 + 4 * (0x2000 + i)];   // the dump's
    // say it: a capture without nvram_start cannot be compared with MAME's run, which started from
    // the files mame_boot_capture.py copies there
    if (!nv_ok || rtcnv.empty()) {
        std::string what;
        if (!nv_ok) what += "blank flash";
        if (rtcnv.empty()) what += what.empty() ? "the RTC at its reset default" : " and the RTC at its reset default";
        fprintf(stderr, "no %snvram_start: the board starts with %s, not MAME's run's NVRAM\n",
                bdir.c_str(), what.c_str());
    }
    auto dongle = load(bdir + "dongle.bin", 256);
    // VRAM: the GCU's hornet_ddr3 on the DE10-nano's DDR3 (+ddrlat, +ddrbusy)
    Ddr3Model ddr;
    {
        const char *a;
        if ((a = Verilated::commandArgsPlusMatch("ddrlat=")) && *a) ddr.lat = atoi(a + 8);
        if ((a = Verilated::commandArgsPlusMatch("ddrbusy=")) && *a) ddr.busy = atoi(a + 9);
    }

    // the discs: frames, padding to 512, then the TOC block (2 blocks)
    struct Disc { FILE *f = nullptr; uint64_t frames = 0, data_bytes = 0, size = 0; std::vector<uint8_t> toc; };
    Disc disc[2];
    for (int d = 0; d < 2; d++) {
        disc[d].f = fopen(cdf[d].c_str(), "rb");
        if (!disc[d].f) { fprintf(stderr, "cannot open %s\n", cdf[d].c_str()); return 1; }
        fseek(disc[d].f, 0, SEEK_END);
        disc[d].frames = (uint64_t)ftell(disc[d].f) / 2352;
        disc[d].data_bytes = ((disc[d].frames * 2352 + 511) / 512) * 512;
        disc[d].size = disc[d].data_bytes + 1024;
        std::vector<std::pair<uint32_t, bool>> trk;      // start, audio
        FILE *c = fopen(cuef[d].c_str(), "r");
        char line[256]; bool audio = false;
        while (c && fgets(line, sizeof line, c)) {
            if (strstr(line, "TRACK")) audio = strstr(line, "AUDIO") != nullptr;
            int mm, ss, ff;
            if (sscanf(line, " INDEX 01 %d:%d:%d", &mm, &ss, &ff) == 3) trk.push_back({(uint32_t)((mm * 60 + ss) * 75 + ff), audio});
        }
        if (c) fclose(c);
        auto &t = disc[d].toc;
        t.assign(1024, 0);
        t[0] = 'F'; t[1] = 'B'; t[2] = 'T'; t[3] = 'C'; t[4] = (uint8_t)trk.size(); t[5] = 1;
        for (size_t i = 0; i <= trk.size(); i++) {
            uint32_t st = i < trk.size() ? trk[i].first : (uint32_t)disc[d].frames;
            bool au = i < trk.size() ? trk[i].second : false;
            uint8_t *e = &t[8 + 8 * i];
            e[0] = st; e[1] = st >> 8; e[2] = st >> 16; e[3] = st >> 24; e[4] = au ? 1 : 0; e[5] = 0;
        }
        fprintf(stderr, "disc %d: %llu frames, %zu tracks\n", d, (unsigned long long)disc[d].frames, trk.size());
    }
    auto disc_byte = [&](int d, uint64_t off) -> uint8_t {
        static std::vector<uint8_t> cache[2]; static uint64_t cbase[2] = {~0ull, ~0ull};
        if (off >= disc[d].data_bytes) { uint64_t o = off - disc[d].data_bytes; return o < 1024 ? disc[d].toc[o] : 0; }
        if (off >= disc[d].frames * 2352) return 0;
        uint64_t b = off & ~65535ull;
        if (cbase[d] != b) { cache[d].assign(65536, 0); fseek(disc[d].f, (long)b, SEEK_SET); fread(cache[d].data(), 1, 65536, disc[d].f); cbase[d] = b; }
        return cache[d][off - b];
    };

    // the input events, by MAME frame
    struct Ev { long f; int mask, len; };
    long anchor_idx = 0, anchor_mame = 0;
    std::vector<Ev> evs;
    {
        std::string e = arg("events", "");
        const char *q = e.c_str();
        while (*q) {
            Ev v; int n = 0;
            if (sscanf(q, "%ld:%x:%d%n", &v.f, &v.mask, &v.len, &n) != 3) break;
            evs.push_back(v);
            q += n; if (*q == ',') q++;
        }
    }

    // MAME's streams
    std::map<std::string, Stream> st;
    {
        FILE *io = fopen((bdir + "io.txt").c_str(), "r");
        if (!io) { fprintf(stderr, "no %sio.txt\n", bdir.c_str()); return 1; }
        char line[128]; long fr = 0; size_t n = 0;
        while (fgets(line, sizeof line, io)) {
            if (line[0] == 'F') { fr = atol(line + 2); if (fr > frames_max + 200) break; continue; }
            Acc x; if (sscanf(line, " %c %x %x %x", &x.rw, &x.a, &x.m, &x.d) != 4) continue;
            x.frame = fr;
            std::string k = stream_of(x);
            if (k.empty()) continue;
            auto &v = st[k].mame;
            // runs of identical reads count once
            if (x.rw == 'R' && !v.empty() && v.back().rw == 'R' && v.back().a == x.a && v.back().m == x.m && ((v.back().d ^ x.d) & x.m) == 0) continue;
            v.push_back(x); n++;
        }
        fclose(io);
        fprintf(stderr, "MAME: %zu compared accesses in %zu streams\n", n, st.size());
        // the anchor: MAME's last ATA register write before the first event
        if (!evs.empty() && stf.empty()) {
            auto &aw = st["ATA_W"].mame;
            for (size_t i = 0; i < aw.size() && aw[i].frame < evs[0].f; i++) { anchor_idx = (long)i + 1; anchor_mame = aw[i].frame; }
            fprintf(stderr, "anchor: ATA write %ld, MAME frame %ld\n", anchor_idx, anchor_mame);
        }
    }

    Vtb_boot *t = new Vtb_boot;
    t->clk = 0; t->reset = 1; t->ce = 1; t->tb_en = 1; t->irq_force = 0;
    t->dma_hold = 1;                    // MAME's order of accesses
    t->in0 = 0x7f; t->in1 = 0xff; t->in2 = 0xff; t->in3 = 0xff; t->sensors = 0; t->cabinet_info = 8;
    t->vblank = 0; t->img_mounted = 0; t->sd_ack = 0; t->sd_buff_wr = 0; t->rtc_set = 0; t->por = 1;
    t->rtc_time = 0x07'01'01'01'00'00'00ull;   // 2001-01-01 00:00:00, a Monday (weekday 2); MAME uses the host's
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->por = 0;
    // the loads happen with the board in reset and power-on over (firebeat_sys)
    for (size_t i = 0; i < dongle.size(); i++) { t->dg_we = 1; t->dg_addr = i; t->dg_data = dongle[i]; tick(); }
    t->dg_we = 0;
    for (size_t i = 0; i < rtcnv.size(); i++) { t->rtc_nv_we = 1; t->rtc_nv_addr = i; t->rtc_nv_wdata = rtcnv[i]; tick(); }
    t->rtc_nv_we = 0;
    t->rtc_set = 1; tick(); t->rtc_set = 0;
    t->dump_start = 0; t->ld_we = 0;
    if (!stf.empty()) {
        // SDRAM and VRAM from the file; the CPU held (ce low) from reset, so nothing is in flight
        // when its state is written
        for (uint32_t a = 0; a < 0x2600000; a += 4) {
            uint32_t w = stw(0x20000 + a);
            for (int b = 0; b < 4; b++) sd[a + b] = w >> (24 - 8 * b);
        }
        memcpy(ddr.mem.data(), stf.data() + 0x2620000, 0x2000000);
        t->ce = 0; t->reset = 0;
        tick();
        auto poke = [&](int sel, uint32_t v) { t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_wdata = v; tick(); t->dbg_we = 0; };
        for (int k = 0; k <= 62; k++) if (k != 53 && k != 58) poke(k, stw(0x1000 + 4 * k));
        poke(58, stw(0x1000 + 4 * 58));     // after 52, which sets both
        poke(53, stw(0x1000 + 4 * 53));
        fprintf(stderr, "state %s: PC %08X\n", state_f.c_str(), stw(0x1000 + 4 * 37));
    }
    t->reset = 0;

    // mount both discs
    for (int d = 0; d < 2; d++) { t->img_size = disc[d].size; t->img_mounted = 1 << d; tick(); }
    t->img_mounted = 0;

    struct Req { bool on = false; int wait = 0; };
    Req cr_, mr, wr;
    // the slots: a request's state
    struct Sd { int state = 0; long wait = 0; uint64_t off = 0; int words = 0, w = 0; } sdq[2];
    int sd_active = -1;

    uint64_t cyc = 0, frame_clk = 0;
    int dump_state = 0;                 // 1 started, 2 held and written
    // +state's device blocks: 0 waiting for the mounts, 1 writing, 2 done
    int ld_phase = stf.empty() ? 2 : 0, ld_i = 0, served[2] = {0, 0};
    long ld_wait = 0;
    // the register-block words +state writes (fb_board st_a): the devices, ATAPI to the DCR store
    const uint32_t ld_lo = 0x100, ld_hi = 0x600;
    long frames = 0;
    bool vb = false;
    long dev_total = 0;
    long anchor_rtl = stf.empty() ? -1 : 0;   // +state: events count from the run's first frame
    // the bench's own state, saved with the model
    auto bench_io = [&](auto &os, bool out) {
        auto raw = [&](void *p, size_t n) {
            if constexpr (std::is_same_v<std::decay_t<decltype(os)>, VerilatedSave>) os.write(p, n);
            else os.read(p, n);
        };
        raw(sd.data(), sd.size()); ddr.io(raw, out);
        raw(&cyc, sizeof cyc); raw(&frame_clk, sizeof frame_clk); raw(&frames, sizeof frames); raw(&vb, sizeof vb);
        raw(&dev_total, sizeof dev_total); raw(&anchor_rtl, sizeof anchor_rtl); raw(sdq, sizeof sdq); raw(&sd_active, sizeof sd_active);
        Req *rs[3] = {&cr_, &mr, &wr};
        for (Req *r : rs) raw(r, sizeof *r);
        // the streams by name: which exist depends on how much of MAME's log was read (+frames)
        auto one = [&](Stream &q) {
            raw(&q.pos, sizeof q.pos); raw(&q.last_rtl, sizeof q.last_rtl); raw(&q.have_last, sizeof q.have_last);
            raw(&q.compared, sizeof q.compared); raw(&q.diverged, sizeof q.diverged);
        };
        uint32_t ns = st.size();
        raw(&ns, sizeof ns);
        if (out) for (auto &kv : st) { uint32_t l = kv.first.size(); raw(&l, sizeof l); raw((void *)kv.first.data(), l); one(kv.second); }
        else for (uint32_t i = 0; i < ns; i++) {
            uint32_t l; raw(&l, sizeof l);
            std::string k(l, ' '); raw(k.data(), l);
            one(st[k]);
        }
    };
    if (!restore_f.empty()) {
        VerilatedRestore rs; rs.open(restore_f.c_str());
        rs >> *t;
        bench_io(rs, false);
        rs.close();
        fprintf(stderr, "restored %s at frame %ld\n", restore_f.c_str(), frames);
    }
    while (frames < frames_max && !Verilated::gotFinish()) {
        t->clk = 0;
        if (reset_at >= 0 && cyc >= (uint64_t)reset_at && !cr_.on && !mr.on && !wr.on && sd_active < 0) {
            fprintf(stderr, "board reset at clock %llu\n", (unsigned long long)cyc);
            reset_at = -1; reset_left = 16;
        }
        t->reset = reset_left > 0;
        if (reset_left > 0) reset_left--;
        t->c_ack = 0; t->m_ack = 0; t->w_ack = 0;
        if (cr_.on && cr_.wait == 0) {
            uint32_t a = (uint32_t)t->c_addr << 4;
            if (t->c_we) for (int k = 0; k < 4; k++) for (int b = 0; b < 4; b++) sd[a + 4 * k + b] = t->c_wdata[k] >> (24 - 8 * b);
            else for (int k = 0; k < 4; k++) t->c_rdata[k] = be32(&sd[a + 4 * k]);
            t->c_ack = 1; cr_.on = false;
        }
        if (mr.on && mr.wait == 0) {
            uint32_t a = (uint32_t)t->m_addr << 5;
            for (int k = 0; k < 8; k++) t->m_rdata[k] = be32(&sd[a + 4 * k]);
            t->m_ack = 1; mr.on = false;
        }
        if (wr.on && wr.wait == 0) {
            uint32_t a = (uint32_t)t->w_addr << 2;
            if (t->w_we) { for (int b = 0; b < 4; b++) if (t->w_be & (8 >> b)) sd[a + b] = t->w_wdata >> (24 - 8 * b); }
            else t->w_rdata = be32(&sd[a]);
            t->w_ack = 1; wr.on = false;
        }
        // the slots (hps_io): one request at a time, ~0.5 ms before its data, then a word every 4 clocks
        t->sd_buff_wr = 0;
        for (int d = 0; d < 2; d++) {
            Sd &q = sdq[d];
            uint32_t lba = d ? t->sd_lba1 : t->sd_lba0;
            int cnt = d ? t->sd_blk_cnt1 : t->sd_blk_cnt0;
            if (q.state == 0 && (t->sd_rd >> d & 1) && sd_active < 0) { q.state = 1; q.wait = sd_wait(); q.off = (uint64_t)lba * 512; q.words = (cnt + 1) * 256; q.w = 0; sd_active = d; }
            else if (q.state == 1 && --q.wait <= 0) { q.state = 2; t->sd_ack |= 1 << d; q.wait = 0; }
            else if (q.state == 2) {
                if (++q.wait >= 4) {
                    q.wait = 0;
                    uint64_t o = q.off + 2 * (uint64_t)q.w;
                    t->sd_buff_dout = disc_byte(d, o) | disc_byte(d, o + 1) << 8;
                    t->sd_buff_wr = 1;
                    if (++q.w == q.words) q.state = 3;
                }
            } else if (q.state == 3) { t->sd_ack &= ~(1 << d); q.state = 0; sd_active = -1; served[d]++; }
        }
        // vblank as MAME's screen: 59.94 Hz (25.175 MHz, 525 lines, 45 blank) or 58.49 Hz (16.6666 MHz,
        // 416 lines, 32 blank), from control_w bit 0
        bool b24 = t->control & 1;
        uint64_t period = b24 ? 1139840 : 1112223;
        uint64_t vstart = b24 ? 1052160 : 1016889;
        frame_clk++;
        if (frame_clk >= period) frame_clk = 0;
        bool v = frame_clk >= vstart;
        t->vblank = v;
        t->ld_we = 0;
        if (ld_phase == 0 && served[0] && served[1] && sd_active < 0 && ++ld_wait > 1000) { ld_phase = 1; ld_i = ld_lo; }
        if (ld_phase == 1) {
            t->ld_we = 1; t->ld_a = ld_i; t->ld_d = stw(0x1000 + 4 * ld_i);
            if (++ld_i == (int)ld_hi) {
                ld_phase = 2; t->ce = 1;
                fprintf(stderr, "state: device blocks loaded at clock %llu; the CPU runs\n", (unsigned long long)cyc);
            }
        }
        t->eval();

        if (anchor_rtl < 0 && anchor_idx > 0 && (long)st["ATA_W"].pos >= anchor_idx) {
            anchor_rtl = frames;
            fprintf(stderr, "frame %ld: anchor reached (MAME frame %ld)\n", frames, anchor_mame);
        }
        if (anchor_rtl >= 0) {
            uint8_t in0 = 0x7f;
            for (auto &v : evs) {
                long at = anchor_rtl + (v.f - anchor_mame);
                if (frames >= at && frames < at + v.len) in0 &= ~v.mask;
            }
            if (in0 != t->in0) fprintf(stderr, "frame %ld: IN0 %02X\n", frames, in0);
            t->in0 = in0;
        }
        if (t->mon_v) {
            Acc x{t->mon_we ? 'W' : 'R', t->mon_addr, t->mon_mask, t->mon_data, frames};
            std::string k = stream_of(x);
            if (!k.empty()) {
                Stream &q = st[k];
                bool dup = x.rw == 'R' && q.have_last && q.last_rtl.a == x.a && q.last_rtl.m == x.m && ((q.last_rtl.d ^ x.d) & x.m) == 0;
                q.last_rtl = x; q.have_last = true;
                if (!dup) {
                    dev_total++;
                    if (q.pos >= q.mame.size()) {
                        if (!q.diverged) fprintf(stderr, "%s: RTL frame %ld has %c %08X %08X %08X beyond MAME's %zu\n", k.c_str(), frames, x.rw, x.a, x.m, x.d, q.mame.size());
                        q.diverged = true;
                    } else {
                        const Acc &e = q.mame[q.pos];
                        if (!q.diverged && (e.rw != x.rw || e.a != x.a || e.m != x.m || ((e.d ^ x.d) & e.m))) {
                            fprintf(stderr, "%s DIVERGES at entry %zu: MAME frame %ld %c %08X %08X %08X, RTL frame %ld %c %08X %08X %08X\n",
                                    k.c_str(), q.pos, e.frame, e.rw, e.a, e.m, e.d & e.m, frames, x.rw, x.a, x.m, x.d);
                            q.diverged = true;
                        }
                        q.pos++; q.compared++;
                    }
                }
            }
        }
        if (t->bad) { fprintf(stderr, "frame %ld: a model met a mode it does not run\n", frames); break; }
        if (iolog_from >= 0 && frames >= iolog_from && t->mon_v && (t->mon_addr & 0xffffff00) != 0x7e800000 && (t->mon_addr & 0xfffffff0) != 0x7d000340 && t->mon_addr != 0x7d000800) fprintf(stderr, "A %ld %c %08X %08X %08X\n", frames, t->mon_we ? 'W' : 'R', t->mon_addr, t->mon_mask, t->mon_data);
        if (trace_from >= 0 && frames >= trace_from && t->dbg_exec) fprintf(stderr, "X %08X %08X\n", t->dbg_pc, t->dbg_ir);
        if (reg_from >= 0 && frames >= reg_from && t->dbg_exec) {
            if (std::find(regpc.begin(), regpc.end(), t->dbg_pc) != regpc.end() || (t->dbg_pc >= reg_lo && t->dbg_pc <= reg_hi)) {
                fprintf(stderr, "R %ld %08X", frames, t->dbg_pc);
                for (int r = 0; r <= 33; r++) { t->dbg_sel = r; t->eval(); fprintf(stderr, " %08X", t->dbg_val); }
                fprintf(stderr, "\n");
                t->dbg_sel = 0; t->eval();
            }
        }

        if (t->c_req && !cr_.on && !t->c_ack) { cr_.on = true; cr_.wait = lat - 1; }
        if (t->m_req && !mr.on && !t->m_ack) { mr.on = true; mr.wait = lat - 1; }
        if (t->w_req && !wr.on && !t->w_ack) { wr.on = true; wr.wait = lat - 1; }
        ddr.sample(t);
        t->clk = 1; t->eval();
        ddr.drive(t);
        for (Req *r : {&cr_, &mr, &wr}) if (r->on && r->wait > 0) r->wait--;
        cyc++;
        if (dump_state == 1 && t->dump_start) t->dump_start = 0;
        else if (dump_state == 1 && t->dump_held) {
            std::string f = bdir + "dump_" + std::to_string(frames) + ".bin";
            FILE *o = fopen(f.c_str(), "wb");
            fwrite(ddr.dump.data(), 8, ddr.dump.size(), o);
            fwrite(ddr.mem.data(), 8, ddr.mem.size(), o);
            fclose(o);
            const uint8_t *dp = (const uint8_t *)ddr.dump.data();
            long bad = 0;
            for (uint32_t a = 0; a < 0x2600000; a += 4) {
                const uint8_t *q = dp + 0x20000 + a;
                uint32_t w = q[0] | q[1] << 8 | q[2] << 16 | (uint32_t)q[3] << 24;
                if (w != be32(&sd[a]) && bad++ < 4) fprintf(stderr, "dump: SDRAM %07X %08X, the bench's %08X\n", a, w, be32(&sd[a]));
            }
            const uint32_t *h = (const uint32_t *)dp, *r = (const uint32_t *)(dp + 0x1000);
            fprintf(stderr, "dump at frame %ld, clock %llu: %s, count %u, PC %08X, LR %08X, MSR %08X; SDRAM %ld words differ\n",
                    frames, (unsigned long long)cyc, f.c_str(), h[1], r[37], r[33], r[36], bad);
            t->dump_start = 1; dump_state = 2;
        } else if (dump_state == 2) { t->dump_start = 0; dump_state = 3; }
        if (v && !vb) {
            frames++;
            if (frames == save_at) {
                std::string f = bdir + "save_" + std::to_string(frames) + ".bin";
                VerilatedSave os; os.open(f.c_str());
                os << *t;
                bench_io(os, true);
                os.close();
                fprintf(stderr, "saved %s\n", f.c_str());
            }
            if (frames % 50 == 0) fprintf(stderr, "frame %ld: PC %08X, %ld device accesses compared\n", frames, t->dbg_pc, dev_total);
            if (frames == dump_at) { t->dump_start = 1; dump_state = 1; }
        }
        vb = v;
    }
    fprintf(stderr, "%ld frames, %llu clocks\n", frames, (unsigned long long)cyc);
    for (auto &kv : st)
        fprintf(stderr, "  %-11s %8ld of %8zu MAME entries compared%s\n", kv.first.c_str(), kv.second.compared, kv.second.mame.size(),
                kv.second.diverged ? "  DIVERGED" : "");
    // flash after the run, for SOUND FLASH INIT checks
    FILE *o = fopen((bdir + "rtl_flash.bin").c_str(), "wb");
    if (o) { fwrite(sd.data() + 0x2000000, 1, 0x600000, o); fclose(o); }
    delete t;
    return 0;
}
