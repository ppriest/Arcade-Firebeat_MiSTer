// SPDX-License-Identifier: GPL-3.0-or-later
//
// PPC403GCX behind its caches (rtl/board/fb_ppc_mem.sv) on a window of a firebeat game, against
// MAME's trace, as sim/ppc_tb does for the bare core (that bench's header describes the window,
// the device replay, the interrupts and the timebase): one line per instruction to <win>/cpu.tr
// for scripts/compare_insn_trace.py.
//
//   scripts/run_verilator.sh cpu_tb +win=debug/ppp11-win21357 +n=2000000 [+lat=N] [+ulat=N]
//
// The caches start empty with ICCR = DCCR = 0x0000FFFF and DCWR = 0, the values ppp's start-up code
// writes (80002150-8000220C): MAME has no cache, so its memory is what the board's memory holds
// with every cache empty. The line port (fills, write-backs) is answered +lat clocks after its
// request from work RAM and the BIOS; the word port (uncached accesses) +ulat clocks after, from
// work RAM or the device replay. The DMA controller is the RTL's (rtl/board/fb_ppc_dma.sv): its
// block reads are answered +lat clocks after from work RAM, its bus accesses +ulat clocks after
// through the device replay. MAME runs a transfer inside the DMACR write, so the core is held (ce
// low) while the DMA is busy, which keeps the device accesses in MAME's order (+dmastall=0 lets
// them interleave). A line the game did not flush before a transfer shows as a GCU write that
// differs from MAME's.

#include "Vtb_cpu.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> load(const std::string &p, size_t size) {
    std::vector<uint8_t> v(size, 0);
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
    size_t n = fread(v.data(), 1, size, f);
    fclose(f);
    fprintf(stderr, "%s: %zu bytes\n", p.c_str(), n);
    return v;
}

static uint32_t be32(const std::vector<uint8_t> &m, uint32_t a) {
    return (uint32_t)m[a] << 24 | (uint32_t)m[a + 1] << 16 | (uint32_t)m[a + 2] << 8 | m[a + 3];
}

static void wr_be(std::vector<uint8_t> &m, uint32_t a, uint32_t v, unsigned be) {
    for (int i = 0; i < 4; i++)
        if (be & (8 >> i)) m[a + i] = (uint8_t)(v >> (24 - 8 * i));
}

static uint32_t be_mask(unsigned be) {
    uint32_t m = 0;
    for (int i = 0; i < 4; i++)
        if (be & (8 >> i)) m |= 0xffu << (24 - 8 * i);
    return m;
}

struct Access { char rw; uint32_t addr, mask, data; };

struct Board {
    std::vector<uint8_t> ram, bios;
    FILE *io = nullptr;
    bool replay = false;
    std::vector<Access> log;
    size_t next = 0;
    bool fail = false;
    bool irq0_ack = false;

    bool mem_rom(uint32_t a) const { return a < 0x2000000 || a >= 0x7ff80000; }

    uint32_t rom_read(uint32_t a) const {
        if (a < 0x2000000) return be32(ram, a);
        return be32(bios, a - 0x7ff80000);
    }

    // a device access, replayed or stubbed
    uint32_t device(char rw, uint32_t a, uint32_t v, unsigned be) {
        uint32_t mask = be_mask(be);
        if (rw == 'W' && a == 0x7e800010 && (be & 8) && !(v & 0x00010000)) irq0_ack = true;
        if (replay) {
            if (next >= log.size()) {
                fprintf(stderr, "replay exhausted at %c %08X\n", rw, a);
                fail = true;
                return 0;
            }
            const Access &e = log[next];
            if (e.rw != rw || e.addr != a || e.mask != mask || (rw == 'W' && ((e.data ^ v) & mask))) {
                fprintf(stderr, "DEVICE DIVERGENCE at access %zu: MAME %c %08X mask %08X data %08X, "
                        "RTL %c %08X mask %08X data %08X\n", next + 1, e.rw, e.addr, e.mask, e.data,
                        rw, a, mask, v & mask);
                fail = true;
                return 0;
            }
            next++;
            return e.data;
        }
        uint32_t r = 0;
        if (io) fprintf(io, "%c %08X %08X %08X\n", rw, a, mask, rw == 'W' ? v & mask : r & mask);
        return r;
    }

    uint32_t read(uint32_t a) {
        a &= 0x7ffffffc;
        if (mem_rom(a)) return rom_read(a);
        return device('R', a, 0, 0xf);
    }

    uint32_t dread(uint32_t a, unsigned be) {
        a &= 0x7ffffffc;
        if (mem_rom(a)) return rom_read(a);
        return device('R', a, 0, be);
    }

    // The 403's DMA controller, as MAME runs it (ppccom.cpp:2497-2505, ppc4xx_dma_exec): a
    // DMACR write with CE set runs a software memory-to-memory transfer to completion at once.
    // Only that mode is modelled; anything else stops the run.
    uint32_t dcr[0x100] = {};
    uint64_t dma_words = 0;
    void dcr_write(unsigned a, uint32_t v) {
        if (a == 0x0e0) { dcr[a] &= ~(v & 0xfff80070); return; }        // DMASR: write 1 to clear
        dcr[a] = v;
        if (a >= 0x0c0 && a <= 0x0d8 && (a & 7) == 0 && (v & 0x80000000)) dma(int((a - 0x0c0) >> 3));
    }
    void dma(int ch) {
        uint32_t *r = &dcr[0x0c0 + 8 * ch];
        uint32_t cr = r[0];
        if (((cr >> 21) & 3) != 2 || ((cr >> 26) & 3) != 2 || !(cr & 0x100) || (cr & 0x40000080)) {
            fprintf(stderr, "DMA mode not modelled: channel %d DMACR %08X\n", ch, cr);
            fail = true;
            return;
        }
        int sinc = (cr & 0x01000000) ? 4 : 0, dinc = (cr & 0x02000000) ? 4 : 0;
        do {
            write(r[2], read(r[3]), 0xf);
            r[3] += sinc; r[2] += dinc;
            dma_words++;
            r[1]--;
        } while ((r[1] & 0xffff) != 0 && !fail);
        dcr[0x0e0] |= 1u << (31 - ch);                                   // terminal count
    }

    void write(uint32_t a, uint32_t v, unsigned be) {
        a &= 0x7ffffffc;
        if (a < 0x2000000) { wr_be(ram, a, v, be); return; }
        if (mem_rom(a)) return;
        device('W', a, v, be);
    }
};

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
            // MAME's debugger can report one instruction more than once with identical state
            // (seen on code the game loaded shortly before): one line each
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
    int lat = (s = Verilated::commandArgsPlusMatch("lat=")) && *s ? atoi(s + 5) : 1;
    std::string win = (s = Verilated::commandArgsPlusMatch("win=")) && *s ? std::string(s + 5) : "";
    if (win.empty()) { fprintf(stderr, "+win=<capture directory> is required\n"); return 1; }

    std::string dir = win + "/";
    Board b;
    b.ram = load(dir + "workram.bin", 0x2000000);
    b.bios = load(dir + "bios.bin", 0x80000);
    std::map<std::string, uint32_t> st;
    Trace mt;
    uint32_t evpr = 0;
    {
        FILE *f = fopen((dir + "state.txt").c_str(), "r");
        if (!f) { fprintf(stderr, "no %sstate.txt\n", dir.c_str()); return 1; }
        char k[32]; unsigned v;
        while (fscanf(f, "%31[^=]=%x\n", k, &v) == 2) st[k] = v;
        fclose(f);
        FILE *io = fopen((dir + "io.txt").c_str(), "r");
        Access e;
        while (io && fscanf(io, " %c %x %x %x", &e.rw, &e.addr, &e.mask, &e.data) == 4) b.log.push_back(e);
        // MAME's log can end mid-line when the capture stops: an unterminated last line is not an access
        if (io && !b.log.empty() && fseek(io, -1, SEEK_END) == 0 && fgetc(io) != '\n') b.log.pop_back();
        if (io) fclose(io);
        b.replay = true;
        mt.open(dir + "trace.tr", n);
        evpr = st["EVPR"] & 0xffff0000;
        fprintf(stderr, "window: %zu device accesses, %zu trace PCs, start PC %08X\n",
                b.log.size(), mt.pcs.size(), st["PC"]);
    }
    FILE *tr = fopen((dir + "cpu.tr").c_str(), "w");
    if (!tr) { fprintf(stderr, "cannot write %scpu.tr\n", dir.c_str()); return 1; }

    Vtb_cpu *t = new Vtb_cpu;
    t->clk = 0; t->reset = 1; t->ce = 0; t->tb_tick = 0; t->ext_irq = 0;
    t->c_ack = 0; t->u_ack = 0; t->dbg_we = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    // a register write between cycles, the core held
    auto poke = [&](int sel, uint32_t v) {
        int ce = t->ce;
        t->ce = 0; t->dbg_we = 1; t->dbg_wsel = sel; t->dbg_wdata = v;
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
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
    // the capture point fell where MAME takes an external interrupt before the first traced line
    if (!mt.pcs.empty() && mt.pcs[0] == (evpr | 0x500) && st["PC"] != mt.pcs[0]) t->ext_irq |= 1;
    t->ce = 1;

    int ulat = (s = Verilated::commandArgsPlusMatch("ulat=")) && *s ? atoi(s + 6) : 1;
    long udbg = (s = Verilated::commandArgsPlusMatch("udbg=")) && *s ? atol(s + 6) : -1;   // print port traffic from this instruction
    // the line and word ports: one request each, answered `lat` / `ulat` clocks after it is seen
    struct Req { bool on = false; int wait = 0; };
    Req cr_, ur, mr, br;
    int dmastall = (s = Verilated::commandArgsPlusMatch("dmastall=")) && *s ? atoi(s + 10) : 1;
    uint64_t dma_blocks = 0;
    uint64_t fills = 0, wbacks = 0, uncached = 0, cops[8] = {};
    auto line_addr = [](uint32_t sd) -> uint32_t {     // SDRAM byte address -> board
        return sd >= 0x2800000 ? 0x7ff80000 + (sd - 0x2800000) : sd;
    };
    uint32_t tsr_now = 0;                       // TSR bits to raise before the next cycle
    int tb_sel = -1;                            // timebase half to load before the next cycle
    uint32_t tb_val = 0;
    long insns = 0;
    uint64_t cyc = 0;
    // +idle=LO-HI,LO-HI,... (hex PCs): clocks are charged to the instruction that last started,
    // and split into idle and work by these ranges (HARDWARE_NOTES, "Play", for ppp11)
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
    uint64_t idle_cyc = 0, work_cyc = 0, idle_ins = 0, work_ins = 0;
    long vblanks = 0;
    while (insns < n && !Verilated::gotFinish() && !b.fail) {
        // pokes go in between cycles, before the next one is evaluated: a poke inside the cycle
        // an instruction starts in disturbs it
        if (tsr_now) { poke(49, tsr_now); tsr_now = 0; }
        if (tb_sel >= 0) { poke(tb_sel, tb_val); tb_sel = -1; }
        t->clk = 0;
        t->c_ack = 0; t->u_ack = 0; t->m_ack = 0; t->b_ack = 0;
        if (mr.on && mr.wait == 0) {
            uint32_t a = (uint32_t)t->m_addr << 5;
            for (int k = 0; k < 8; k++) t->m_rdata[k] = a < 0x2000000 ? be32(b.ram, a + 4 * k) : 0;
            t->m_ack = 1; mr.on = false; dma_blocks++;
        }
        if (br.on && br.wait == 0) {
            t->b_ack = 1;
            if (t->b_we) { b.write(t->b_addr, t->b_wdata, 0xf); b.dma_words++; t->b_rdata = 0; }
            else t->b_rdata = b.dread(t->b_addr, 0xf);
            br.on = false;
        }
        if (t->g_we) { b.write(t->g_port ? 0x7e800074 : 0x7e800070, t->g_data, 0xf); b.dma_words++; }
        if (t->dma_bad) { fprintf(stderr, "DMA mode not run by fb_ppc_dma\n"); b.fail = true; }
        if (dmastall) t->ce = !t->dma_busy;
        if (cr_.on && cr_.wait == 0) {
            uint32_t a = line_addr((uint32_t)t->c_addr << 4);
            t->c_ack = 1;
            if (t->c_we) {
                wbacks++;
                if (a < 0x2000000) for (int k = 0; k < 4; k++) wr_be(b.ram, a + 4 * k, t->c_wdata[k], 0xf);
            } else {
                fills++;
                for (int k = 0; k < 4; k++) t->c_rdata[k] = b.rom_read(a + 4 * k);
            }
            cr_.on = false;
        }
        if (ur.on && ur.wait == 0) {
            t->u_ack = 1;
            uncached++;
            if (t->u_we) { b.write(t->u_addr, t->u_wdata, t->u_be); t->u_rdata = 0; }
            else t->u_rdata = b.dread(t->u_addr, t->u_be);
            ur.on = false;
        }
        if (b.irq0_ack) { t->ext_irq &= ~1; b.irq0_ack = false; }
        t->tb_tick = 0;
        t->eval();
        t->dcr_rdata = b.dcr[t->dcr_addr & 0xff];
        t->eval();
        if (t->dcr_we) b.dcr_write(t->dcr_addr & 0xff, t->dcr_wdata);

        if (t->dbg_exec && t->ce) {          // dbg_exec is not gated by ce
            cur_idle = false;
            for (auto &r : idle) if (t->dbg_pc >= r.first && t->dbg_pc <= r.second) cur_idle = true;
            (cur_idle ? idle_ins : work_ins)++;
            // MAME's next instruction reads the timebase: load the half it reads with the value
            // MAME's trace shows it returning (the timebase is stopped in a window)
            if (insns + 2 < (long)mt.pcs.size()) {
                uint32_t pc1 = mt.pcs[insns + 1];
                uint32_t op1 = (pc1 & 0x7fffffff) < 0x2000000 ? be32(b.ram, pc1 & 0x7ffffffc)
                             : (pc1 & 0x7fffffff) >= 0x7ff80000 ? be32(b.bios, (pc1 & 0x7ffffffc) - 0x7ff80000) : 0;
                if ((op1 >> 26) == 31 && ((op1 >> 1) & 0x3ff) == 339) {
                    unsigned spr = ((op1 >> 11) & 0x1f) << 5 | ((op1 >> 16) & 0x1f);
                    tb_sel = (spr == 0x3dd || spr == 0x3cd) ? 46 : (spr == 0x3dc || spr == 0x3cc) ? 47 : -1;
                    if (tb_sel >= 0) tb_val = mt.gpr(insns + 2, (op1 >> 21) & 31);
                }
            }
            for (int i = 0; i < 37; i++) {
                t->dbg_sel = i; t->eval();
                fprintf(tr, "%08X ", t->dbg_val);
            }
            fprintf(tr, "%08X: %08X\n", t->dbg_pc, t->dbg_ir);
            // MAME's next instruction is an interrupt vector not reached by falling through:
            // raise the source now, after this instruction has been decided
            if (insns + 1 < (long)mt.pcs.size() && mt.pcs[insns] + 4 != mt.pcs[insns + 1]) {
                if (mt.pcs[insns + 1] == (evpr | 0x500)) { t->ext_irq |= 1; t->eval(); vblanks++; }
                if (mt.pcs[insns + 1] == (evpr | 0x1000)) tsr_now |= 0x08000000;
                if (mt.pcs[insns + 1] == (evpr | 0x1010)) tsr_now |= 0x04000000;
            }
            insns++;
        }
        if (t->c_req && !cr_.on && !t->c_ack) { cr_.on = true; cr_.wait = lat - 1; }
        if (t->u_req && !ur.on && !t->u_ack) { ur.on = true; ur.wait = ulat - 1; }
        if (t->m_req && !mr.on && !t->m_ack) { mr.on = true; mr.wait = lat - 1; }
        if (t->b_req && !br.on && !t->b_ack) { br.on = true; br.wait = ulat - 1; }
        if (t->d_req_o) cops[t->d_cop_o]++;            // a request is one clock
        if (udbg >= 0 && insns >= udbg) {
            if (t->u_req && !ur.on) fprintf(stderr, "%lld U %c %08X\n", (long long)insns, t->u_we ? 'W' : 'R', (unsigned)t->u_addr);
            if (t->c_req && !cr_.on) fprintf(stderr, "%lld L %c %07X\n", (long long)insns, t->c_we ? 'W' : 'R', (unsigned)t->c_addr << 4);
            if (t->dbg_exec && t->ce) fprintf(stderr, "%lld X %08X %08X\n", (long long)insns, t->dbg_pc, t->dbg_ir);
        }
        t->clk = 1; t->eval();
        if (cr_.on && cr_.wait > 0) cr_.wait--;
        if (ur.on && ur.wait > 0) ur.wait--;
        if (mr.on && mr.wait > 0) mr.wait--;
        if (br.on && br.wait > 0) br.wait--;
        cyc++;
        (cur_idle ? idle_cyc : work_cyc)++;
    }
    fclose(tr);
    fprintf(stderr, "%ld instructions, %llu clocks (%.2f clocks/insn)", insns,
            (unsigned long long)cyc, insns ? (double)cyc / insns : 0.0);
    if (b.replay) fprintf(stderr, ", %zu of %zu device accesses replayed", b.next, b.log.size());
    fprintf(stderr, ", %llu DMA words", (unsigned long long)b.dma_words);
    fprintf(stderr, "\nline port (lat %d): %llu fills, %llu write-backs; word port (lat %d): %llu accesses; "
            "dcbf %llu dcbst %llu dcbi %llu dccci %llu icbi %llu iccci %llu",
            lat, (unsigned long long)fills, (unsigned long long)wbacks, ulat, (unsigned long long)uncached,
            (unsigned long long)cops[1], (unsigned long long)cops[2], (unsigned long long)cops[3],
            (unsigned long long)cops[4], (unsigned long long)cops[5], (unsigned long long)cops[6]);
    if (!idle.empty())
        fprintf(stderr, "\nwork: %llu instructions, %llu clocks (%.2f/insn); idle: %llu instructions, "
                "%llu clocks; %ld vblank interrupts",
                (unsigned long long)work_ins, (unsigned long long)work_cyc,
                work_ins ? (double)work_cyc / work_ins : 0.0, (unsigned long long)idle_ins,
                (unsigned long long)idle_cyc, vblanks);
    fprintf(stderr, "\n");
    delete t;
    return b.fail ? 2 : 0;
}
