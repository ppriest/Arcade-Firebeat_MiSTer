// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/board/fb_board.sv on a window of a firebeat game (scripts/mame_ppc_window.py), against MAME:
//
//   scripts/run_verilator.sh board_tb +win=debug/ppp11-win21357 +n=2000000 [+lat=N] [+idle=...]
//       [+hold=0 +nocheck]
//
// +hold=0: the DMA runs beside the CPU (fb_board dma_hold low, the hardware core's setting); the
// order of accesses then differs from MAME's, so with +nocheck nothing is compared and the run
// measures the clocks of each MAME frame's work (+idle).
//   -> <win>/board.tr, one line per instruction, for scripts/compare_insn_trace.py --rtl board.tr
//
// The board's own devices answer the CPU and the DMA (fb_spu, fb_pc16552, fb_rtc65271, fb_flash,
// fb_ata, the GCU and YMZ280B shells, the I/O registers); every access to the ranges MAME's capture
// taps is compared, in order, with io.txt: a write's data, and a read's data as the RTL model
// returned it.
//
// Memories: SDRAM as firebeat_sys lays it out (work RAM from workram.bin, the three flash chips and
// the RTC from the window's MAME NVRAM files, the BIOS), answered +lat clocks after a request; VRAM
// on hornet_ddr3 and sim/common/ddr3_model.h (+ddrlat, +ddrbusy).
//
// As sim/cpu_tb: the window starts from MAME's registers with the caches empty (ICCR = DCCR =
// 0x0000FFFF, DCWR = 0); the timebase is stopped and each read of it loaded with MAME's value; the
// PIT and FIT interrupts and IRQ0 (vblank, through irq_force, the GCU's own vblank input held low)
// are raised where MAME's trace takes them, IRQ0 dropped at the GCU write that clears it; the core
// is held while the DMA runs (MAME's order of accesses). Inputs are MAME's idle values (IN0 0x7F).

#include "Vtb_board.h"
#include "verilated.h"
#include "../common/ddr3_model.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> load(const std::string &p, size_t size, bool must = true) {
    std::vector<uint8_t> v(size, 0);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { if (must) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); } return v; }
    size_t n = fread(v.data(), 1, size, f);
    fclose(f);
    fprintf(stderr, "%s: %zu bytes\n", p.c_str(), n);
    v.resize(n);
    return v;
}

static uint32_t be32(const uint8_t *m) { return (uint32_t)m[0] << 24 | (uint32_t)m[1] << 16 | (uint32_t)m[2] << 8 | m[3]; }

struct Access { char rw; uint32_t addr, mask, data; };

// MAME's trace: the PC of every line, and where each line starts for reading registers back
struct Trace {
    FILE *f = nullptr;
    std::vector<uint32_t> pcs;
    std::vector<long> offs;
    void open(const std::string &path, long n) {
        f = fopen(path.c_str(), "r");
        if (!f) return;
        static char line[1024];
        std::string prev;
        long off = ftell(f);
        while ((long)pcs.size() < n + 1 && fgets(line, sizeof line, f)) {
            char *c = strchr(line, ':');
            if (c && c - line >= 8 && prev != line) {
                pcs.push_back((uint32_t)strtoul(c - 8, nullptr, 16));
                offs.push_back(off);
            }
            prev = line;
            off = ftell(f);
        }
    }
    uint32_t gpr(long i, int r) {
        static char line[1024];
        fseek(f, offs[i], SEEK_SET);
        if (!fgets(line, sizeof line, f)) return 0;
        return (uint32_t)strtoul(line + 9 * r, nullptr, 16);
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 100000;
    int lat = (s = Verilated::commandArgsPlusMatch("lat=")) && *s ? atoi(s + 5) : 12;
    std::string win = (s = Verilated::commandArgsPlusMatch("win=")) && *s ? std::string(s + 5) : "";
    if (win.empty()) { fprintf(stderr, "+win=<capture directory> is required\n"); return 1; }
    std::string dir = win + "/";

    // SDRAM: work RAM, flash x 3, BIOS
    std::vector<uint8_t> sd(0x4000000, 0);
    {
        auto ram = load(dir + "workram.bin", 0x2000000);
        memcpy(sd.data(), ram.data(), ram.size());
        const char *fl[3] = {"flash_main", "flash_snd1", "flash_snd2"};
        for (int k = 0; k < 3; k++) {
            auto f = load(dir + "nvram/ppp11/" + fl[k], 0x200000);
            memcpy(sd.data() + 0x2000000 + 0x200000 * k, f.data(), f.size());
        }
        auto bios = load(dir + "bios.bin", 0x80000);
        memcpy(sd.data() + 0x2800000, bios.data(), bios.size());
    }
    auto rtcnv = load(dir + "nvram/ppp11/rtc", 4152);
    // VRAM: the GCU's hornet_ddr3 on the DE10-nano's DDR3 (+ddrlat, +ddrbusy)
    Ddr3Model ddr;
    {
        const char *a;
        if ((a = Verilated::commandArgsPlusMatch("ddrlat=")) && *a) ddr.lat = atoi(a + 8);
        if ((a = Verilated::commandArgsPlusMatch("ddrbusy=")) && *a) ddr.busy = atoi(a + 9);
    }

    std::map<std::string, uint32_t> st;
    std::vector<Access> log;
    Trace mt;
    uint32_t evpr;
    {
        FILE *f = fopen((dir + "state.txt").c_str(), "r");
        if (!f) { fprintf(stderr, "no %sstate.txt\n", dir.c_str()); return 1; }
        char k[32]; unsigned v;
        while (fscanf(f, "%31[^=]=%x\n", k, &v) == 2) st[k] = v;
        fclose(f);
        FILE *io = fopen((dir + "io.txt").c_str(), "r");
        Access e;
        while (io && fscanf(io, " %c %x %x %x", &e.rw, &e.addr, &e.mask, &e.data) == 4) log.push_back(e);
        // MAME's log can end mid-line when the capture stops: an unterminated last line is not an access
        if (io && !log.empty() && fseek(io, -1, SEEK_END) == 0 && fgetc(io) != '\n') log.pop_back();
        if (io) fclose(io);
        mt.open(dir + "trace.tr", n);
        evpr = st["EVPR"] & 0xffff0000;
        fprintf(stderr, "window: %zu device accesses, %zu trace PCs, start PC %08X\n", log.size(), mt.pcs.size(), st["PC"]);
    }
    FILE *tr = fopen((dir + "board.tr").c_str(), "w");

    Vtb_board *t = new Vtb_board;
    bool nocheck = Verilated::commandArgsPlusMatch("nocheck")[0] != 0;
    t->clk = 0; t->reset = 1; t->ce = 0; t->tb_en = 0; t->irq_force = 0;
    t->dma_hold = (s = Verilated::commandArgsPlusMatch("hold=")) && *s ? atoi(s + 6) : 1;
    t->in0 = 0x7f; t->in1 = 0xff; t->in2 = 0xff; t->in3 = 0xff; t->sensors = 0; t->cabinet_info = 8;
    t->vblank = 0; t->img_mounted = 0; t->sd_ack = 0; t->sd_buff_wr = 0;
    // the DDR3 model steps with every clock, or a beat's DOUT_READY is seen twice
    auto tick = [&]() { t->clk = 0; t->eval(); ddr.sample(t); t->clk = 1; t->eval(); ddr.drive(t); };
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    // the RTC's .nv image through its NVRAM port
    for (size_t i = 0; i < rtcnv.size(); i++) { t->rtc_nv_we = 1; t->rtc_nv_addr = i; t->rtc_nv_wdata = rtcnv[i]; tick(); }
    t->rtc_nv_we = 0;
    auto poke = [&](int sel, uint32_t v) {
        int ce = t->ce;
        t->ce = 0; t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_wdata = v;
        tick();
        t->dbg_we = 0; t->ce = ce;
    };
    for (int i = 0; i < 32; i++) poke(i, st["R" + std::to_string(i)]);
    const char *names[] = {"CR", "LR", "CTR", "XER", "MSR", "PC", "SRR0", "SRR1",
                           "SPRG0", "SPRG1", "SPRG2", "SPRG3", "EXIER", "EVPR", "TBL", "TBH"};
    for (int i = 0; i < 16; i++) poke(32 + i, st[names[i]]);
    poke(48, 0x04800000);                       // TCR: PIE | FIE
    poke(51, 0x0000E401);                       // IOCR
    poke(55, 0x0000FFFF);                       // ICCR, DCCR, DCWR
    poke(56, 0x0000FFFF);
    poke(57, 0x00000000);
    if (!mt.pcs.empty() && mt.pcs[0] == (evpr | 0x500) && st["PC"] != mt.pcs[0]) t->irq_force |= 1;
    t->ce = 1;

    struct Req { bool on = false; int wait = 0; };
    Req cr_, mr, wr;
    size_t next = 0;
    bool fail = false;
    uint32_t tsr_now = 0;
    int tb_sel = -1;
    uint32_t tb_val = 0;
    long insns = 0;
    uint64_t cyc = 0, dev_cmp = 0, cmds = 0;
    // +idle=LO-HI,... (hex PCs, the RTOS's idle task): clocks charged to the instruction that last
    // started, split into idle and work (HARDWARE_NOTES "Play")
    std::vector<std::pair<uint32_t, uint32_t>> idle;
    if ((s = Verilated::commandArgsPlusMatch("idle=")) && *s) {
        const char *q = s + 6;
        while (*q) {
            char *e;
            uint32_t lo = (uint32_t)strtoul(q, &e, 16); q = e + 1;
            uint32_t hi = (uint32_t)strtoul(q, &e, 16); q = e;
            idle.push_back({lo, hi});
            if (*q == ',') q++;
        }
    }
    bool cur_idle = false;
    uint64_t idle_cyc = 0, work_cyc = 0, dma_cyc = 0;
    long vblanks = 0;
    uint64_t last_insn = 0;
    while (insns < n && !Verilated::gotFinish() && !fail) {
        if (tsr_now) { poke(49, tsr_now); tsr_now = 0; }
        if (tb_sel >= 0) { poke(tb_sel, tb_val); tb_sel = -1; }
        t->clk = 0;
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
        t->ce = 1;
        t->eval();

        if (t->mon_v && !nocheck) {
            dev_cmp++;
            char rw = t->mon_we ? 'W' : 'R';
            if (next >= log.size()) { fprintf(stderr, "device log exhausted at %c %08X\n", rw, t->mon_addr); fail = true; }
            else {
                const Access &e = log[next];
                if (e.rw != rw || e.addr != t->mon_addr || e.mask != t->mon_mask || ((e.data ^ t->mon_data) & e.mask)) {
                    fprintf(stderr, "DEVICE DIVERGENCE at access %zu, instruction %ld: MAME %c %08X mask %08X data %08X, "
                            "RTL %c %08X mask %08X data %08X\n", next + 1, insns, e.rw, e.addr, e.mask, e.data & e.mask,
                            rw, t->mon_addr, t->mon_mask, t->mon_data);
                    fail = true;
                }
                if (rw == 'W' && e.addr == 0x7e800010 && (e.mask & 0xffff0000) && !(e.data & 0x00010000)) t->irq_force &= ~1;
                next++;
            }
        }
        if (t->gcu_cmd_v) cmds++;
        if (t->mon_v && nocheck && t->mon_we && t->mon_addr == 0x7e800010 && (t->mon_mask & 0xffff0000) && !(t->mon_data & 0x00010000)) t->irq_force &= ~1;
        if (t->bad) { fprintf(stderr, "a model met a mode it does not run\n"); fail = true; }

        if (t->dbg_exec && t->ce) {
            cur_idle = false;
            for (auto &r : idle) if (t->dbg_pc >= r.first && t->dbg_pc <= r.second) cur_idle = true;
            if (insns + 2 < (long)mt.pcs.size()) {
                uint32_t pc1 = mt.pcs[insns + 1] & 0x7fffffff;
                uint32_t op1 = pc1 < 0x2000000 ? be32(&sd[pc1 & ~3u]) : pc1 >= 0x7ff80000 ? be32(&sd[0x2800000 + ((pc1 & ~3u) - 0x7ff80000)]) : 0;
                if ((op1 >> 26) == 31 && ((op1 >> 1) & 0x3ff) == 339) {
                    unsigned spr = ((op1 >> 11) & 0x1f) << 5 | ((op1 >> 16) & 0x1f);
                    tb_sel = (spr == 0x3dd || spr == 0x3cd) ? 46 : (spr == 0x3dc || spr == 0x3cc) ? 47 : -1;
                    if (tb_sel >= 0) tb_val = mt.gpr(insns + 2, (op1 >> 21) & 31);
                }
            }
            for (int i = 0; i < 37; i++) { t->dbg_sel = i; t->eval(); fprintf(tr, "%08X ", t->dbg_val); }
            fprintf(tr, "%08X: %08X\n", t->dbg_pc, t->dbg_ir);
            if (insns + 1 < (long)mt.pcs.size() && mt.pcs[insns] + 4 != mt.pcs[insns + 1]) {
                if (mt.pcs[insns + 1] == (evpr | 0x500)) {
                    t->irq_force |= 1; t->eval(); vblanks++;
                    // a MAME frame's worth of the board's clocks: from vblank to vblank
                    fprintf(stderr, "vblank %ld at clock %llu (work %llu, idle %llu, DMA %llu)\n", vblanks,
                            (unsigned long long)cyc, (unsigned long long)work_cyc, (unsigned long long)idle_cyc, (unsigned long long)dma_cyc);
                }
                if (mt.pcs[insns + 1] == (evpr | 0x1000)) tsr_now |= 0x08000000;
                if (mt.pcs[insns + 1] == (evpr | 0x1010)) tsr_now |= 0x04000000;
            }
            insns++;
        }
        if (t->c_req && !cr_.on && !t->c_ack) { cr_.on = true; cr_.wait = lat - 1; }
        if (t->m_req && !mr.on && !t->m_ack) { mr.on = true; mr.wait = lat - 1; }
        if (t->w_req && !wr.on && !t->w_ack) { wr.on = true; wr.wait = lat - 1; }
        ddr.sample(t);
        t->clk = 1; t->eval();
        ddr.drive(t);
        for (Req *r : {&cr_, &mr, &wr}) if (r->on && r->wait > 0) r->wait--;
        cyc++;
        if (t->dma_busy) dma_cyc++;
        // no instruction for 1M clocks: the board is stuck
        if (t->dbg_exec && t->ce) last_insn = cyc;
        else if (cyc - last_insn == 1000000) {
            fprintf(stderr, "stuck: no instruction for 1,000,000 clocks after instruction %ld, PC %08X, DMA busy %d\n",
                    insns, t->dbg_pc, t->dma_busy);
            fail = true;
        }
        (cur_idle ? idle_cyc : work_cyc)++;
    }
    fclose(tr);
    if (!idle.empty())
        fprintf(stderr, "work %llu clocks, idle %llu, DMA holding the CPU %llu; %ld vblanks: work %.0f clocks a frame (%.1f%% of 1,128,205)\n",
                (unsigned long long)work_cyc, (unsigned long long)idle_cyc, (unsigned long long)dma_cyc, vblanks,
                vblanks ? (double)work_cyc / vblanks : 0.0, vblanks ? 100.0 * work_cyc / vblanks / 1128205.0 : 0.0);
    fprintf(stderr, "%ld instructions, %llu clocks (%.2f clocks/insn); %llu device accesses compared of %zu; %llu GCU commands\n",
            insns, (unsigned long long)cyc, insns ? (double)cyc / insns : 0.0, (unsigned long long)dev_cmp, log.size(),
            (unsigned long long)cmds);
    t->final();
    delete t;
    return fail ? 2 : 0;
}
