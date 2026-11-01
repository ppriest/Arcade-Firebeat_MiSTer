// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Firebeat board for ParaParaParadise (firebeat.cpp firebeat_ppp_map): the PPC403GCX with its
// caches and DMA, the bus, and the devices. Memories are outside: work RAM, flash and BIOS in SDRAM
// (firebeat_sys's map), VRAM in DDR3.
//
// Bus: the CPU's uncached accesses (fb_ppc_mem's word port) and the DMA's (fb_ppc_dma's bus port),
// one at a time, the DMA first. Physical addresses (31 bits):
//   0x00000000-0x01FFFFFF  work RAM          SDRAM word port
//   0x40000000-0x4000000F  the 403's serial port and the DS1991 (fb_spu), bytes
//   0x70006000             extend board IRQ enable (write), 0x7000A000 its active bits (read, inverted)
//   0x74000000-0x740003FF  SPU shared RAM, absent on ppp: reads 0
//   0x7D000200-0x7D00021F  cabinet: offset 0 cabinet_info << 28, else 0
//   0x7D000320-0x7D000327  lamps (dropped); 0x7D000804 lamps
//   0x7D000340-0x7D00035F  sensors, halfwords 0-3: SENSORn | 0x0100, else 0
//   0x7D000400-0x7D000401  YMZ280B (fb_ymz280b), bytes
//   0x7D000500-0x7D000501  control_w, bytes
//   0x7D000800-0x7D000803  IN0-IN3, bytes
//   0x7D400000, 0x7D800000, 0x7DA00000  the three flash chips (fb_flash), bytes
//   0x7E000000-0x7E00003F  RTC65271 registers, 0x7E000100-0x7E00013F its extended RAM, bytes
//   0x7E800000-0x7E8000FF  GCU (fb_gcu_shell); 0x7E800100-0x7E8001FF reads 0
//   0x7FF80000-0x7FFFFFFF  BIOS              SDRAM word port (writes dropped)
//   0x7FE00000-0x7FE0000F, 0x7FE80000-0x7FE8000F  the ATA's chip selects (fb_ata), halfwords
//                          byte-swapped as cs0_swap_r/w and cs1_swap_r/w
//   0x7DC00000-0x7DC0000F  the PC16552D (fb_pc16552), bytes
//   anything else          reads 0, writes dropped (MAME's unmapped value)
// Byte devices are accessed once per byte lane enabled, halfword devices once per halfword, lane
// 0 (bits 31:24) at the lowest address, as MAME's handlers on the 32-bit big-endian bus.
//
// Interrupts (firebeat.cpp:1152-1160): IRQ0 the GCU, IRQ4 the ATA; the 403's serial port and DMA
// internal. The timebase, PIT and FIT count at 66 MHz: 99 clocks in 100 of clk (66.667 MHz).
//
// mon_*: each bus access to the ranges MAME's capture taps (0x40000000-0x4000000F,
// 0x70000000-0x7FF7FFFF), at its end, as the taps see it (one per CPU or DMA access, the mask from
// the byte enables, the data read or written) -- sim/board_tb compares them with io.txt.

module fb_board (
    input  logic         clk,
    input  logic         reset,
    input  logic         por,            // power-on: the RTC (MAME's has no reset) and the mounted discs, which a board reset leaves alone
    input  logic         ce,             // the CPU's clock enable (pause)
    input  logic         halt,           // the state dump: stop the CPU at an instruction boundary
    output logic         frozen,         // halted, data cache written back, DMA and GCU idle
    input  logic [13:0]  st_a,           // the state dump's register block (docs/STATE.md), word address
    output logic [31:0]  st_d,           // a clock after st_a; read while frozen
    input  logic         st_we,          // write st_wd there: sim/boot_tb's state load (Verilator only)
    input  logic [31:0]  st_wd,
    output logic [1:0]   ata_check,      // a drive's CHECK CONDITION, sense key ata_key (fb_atapi)
    output logic [3:0]   ata_key [2],
    // hold the CPU while the DMA runs, as MAME runs a transfer inside the DMACR write (benches, for
    // MAME's order of accesses; the GCU's status then reads MAME's constant). Low: the DMA runs
    // beside the CPU, as the 403's does, and the GCU's status shows the port it feeds busy.
    input  logic         dma_hold,
    input  logic         tb_en,          // the timebase runs (benches stop it to load MAME's values)
    input  logic [4:0]   irq_force,      // external interrupt lines ORed in (benches)
    output logic         dma_busy,

    // SDRAM (firebeat_sdram ports c, m, w)
    output logic         c_req,
    output logic         c_we,
    output logic [26:4]  c_addr,
    output logic [127:0] c_wdata,
    input  logic         c_ack,
    input  logic [127:0] c_rdata,
    output logic         m_req,
    output logic [26:5]  m_addr,
    input  logic         m_ack,
    input  logic [255:0] m_rdata,
    output logic         w_req,
    output logic         w_we,
    output logic [26:2]  w_addr,
    output logic [3:0]   w_be,
    output logic [31:0]  w_wdata,
    input  logic         w_ack,
    input  logic [31:0]  w_rdata,

    // VRAM (DDR3): the GCU's wide hornet_ddr3 master
    output logic         vm_read,
    output logic         vm_write,
    output logic [31:0]  vm_addr,
    output logic [10:0]  vm_burst,
    output logic [3:0]   vm_be,
    output logic [31:0]  vm_wdata,
    output logic [3:0]   vm_be_hi,
    output logic [31:0]  vm_wdata_hi,
    input  logic         vm_waitn,
    input  logic         vm_rvalid,
    input  logic [31:0]  vm_rdata,
    input  logic [31:0]  vm_rdata_hi,

    // the discs: hps_io image slots 0 (program CD) and 1 (audio CD)
    input  logic [1:0]   img_mounted,
    input  logic [63:0]  img_size,
    output logic [31:0]  sd_lba [2],
    output logic [5:0]   sd_blk_cnt [2],
    output logic [1:0]   sd_rd,
    input  logic [1:0]   sd_ack,
    input  logic         sd_buff_wr,
    input  logic [15:0]  sd_buff_dout,

    input  logic         vblank,
    input  logic [7:0]   in0, in1, in2, in3,
    input  logic [15:0]  sensor [4],
    input  logic [3:0]   cabinet_info,
    output logic signed [15:0] aud_l, aud_r,   // the speaker: YMZ280B and CD audio (firebeat.cpp's routes)
    output logic [7:0]   control,
    output logic         nv_wr,          // a CPU write reached the flash or the RTC: the NVRAM file is stale

    // loading and the NVRAM file
    input  logic         dg_we,          // the dongle image
    input  logic [7:0]   dg_addr,
    input  logic [7:0]   dg_data,
    input  logic         rtc_nv_we,
    input  logic [12:0]  rtc_nv_addr,
    input  logic [7:0]   rtc_nv_wdata,
    output logic [7:0]   rtc_nv_rdata,
    input  logic         rtc_set,
    input  logic [55:0]  rtc_time,

    output logic         gcu_cmd_v,
    output logic         gcu_cmd_port,
    output logic [127:0] gcu_cmd,
    // the GCU's display registers, for fb_gcu_disp
    output logic [2:0][31:0] gd_crtc,
    output logic [15:0]  gd_layer,
    output logic [3:0][15:0] gd_alpha, gd_x, gd_y, gd_w, gd_h,
    output logic [3:0][31:0] gd_base,
    output logic [15:0]  gd_6c,

    output logic         mon_v,
    output logic         mon_we,
    output logic [30:0]  mon_addr,
    output logic [31:0]  mon_mask,
    output logic [31:0]  mon_data,
    output logic         bad,            // a mode or command a model does not run
    // the CPU, for benches and probes
    output logic         dbg_exec,
    output logic [31:0]  dbg_pc,
    output logic [31:0]  dbg_ir,
    input  logic [5:0]   dbg_sel,
    output logic [31:0]  dbg_val,
    input  logic         dbg_we,
    input  logic [5:0]   dbg_wsel,
    input  logic [31:0]  dbg_wdata
);

// ---------------------------------------------------------------- the timebase's 66 MHz
logic [6:0] tb_n;
logic       tick66;
always_ff @(posedge clk) begin
    tb_n <= (tb_n == 7'd99) ? 7'd0 : tb_n + 7'd1;
    tick66 <= tb_n != 7'd99;
    if (reset) tb_n <= 7'd0;
end

// ---------------------------------------------------------------- the CPU
// MAME runs a transfer inside the DMACR write (ppccom.cpp:2497-2505). Here it runs beside the CPU
// (dma_hold low), which waits for its end at a DMA register access: the BIOS rewrites a channel's
// registers as soon as the GCU's status shows the other port free, and a running transfer must not
// take them. dma_hold: the CPU held for the whole transfer, MAME's order of every access
logic dbg_exec_c;
logic        i_req, i_ack, i_a31, d_req, d_we, d_ack, d_a31;
logic [30:0] i_addr, d_addr;
logic [31:0] i_rdata, d_rdata, d_wdata, iccr, dccr, dcwr;
logic [3:0]  d_be;
logic [2:0]  d_cop;
logic        dcr_we_c, dcr_re_c, dma_hit;
logic [9:0]  dcr_addr;
logic [31:0] dcr_wdata, dcr_rdata, dma_rdata;
logic [4:0]  ext_irq;
logic [8:0]  int_irq;
logic [3:0]  dma_irq;
logic        spu_irq_rx, spu_irq_tx, gcu_irq;
logic        dma_bad, spu_bad, flash_bad;

wire dma_wait = dma_busy && (dma_hold || ((dcr_we_c || dcr_re_c) && dma_hit));
// halt runs a paused CPU on to the next instruction start and holds it there; the timebase stops
logic halted;
always_ff @(posedge clk) begin
    if (halt && dbg_exec_c && !dma_wait) halted <= 1'b1;
    if (!halt || reset) halted <= 1'b0;
end
wire ce_cpu = (ce || halt) && !dma_wait && !(halt && (dbg_exec_c || halted));
logic dc_flushed, gcu_idle;
assign frozen = halted && dc_flushed && !dma_busy && gcu_idle;

// the register block (docs/STATE.md): 0x0000 the CPU (ppc403_core's state codes), 0x0100 the ATAPI
// drives, 0x0200 the SPU, 0x0280 the RTC's counters, 0x0300 the flash, 0x0340 the PC16552D,
// 0x0380 the GCU shell, 0x0400 the DMA, 0x0500 the DCR store, 0x0600 the YMZ280B's registers (read
// only), 0x2000 the RTC's NVRAM image a byte a word (its .nv format, 4,152 bytes)
logic [31:0] st_ata_log;
logic [31:0] st_ata, st_spu, st_rtc, st_fl, st_uart, st_gcu, st_dma;
logic [7:0]  st_ymz;
wire  st_hold = halted || st_we;        // the RAMs' read ports follow st_a
wire  st_rtcnv = st_a[13];
always_ff @(posedge clk)
    casez (st_a)
    14'b00_0000_00??_????: st_d <= dbg_val;
    14'b00_0001_????_????: st_d <= st_ata;
    14'b00_0010_0???_????: st_d <= st_spu;
    14'b00_0010_10??_????: st_d <= st_rtc;
    14'b00_0011_00??_????: st_d <= st_fl;
    14'b00_0011_010?_????: st_d <= st_uart;
    14'b00_0011_10??_????: st_d <= st_gcu;
    14'b00_0100_????_????: st_d <= st_dma;
    14'b00_0101_????_????: st_d <= dcr_q;
    14'b00_0110_????_????: st_d <= {24'd0, st_ymz};
    14'b01_????_????_????: st_d <= st_ata_log;       // the slave's access log, then its count at 0x1800
    14'b1?_????_????_????: st_d <= {24'd0, rtc_nv_rdata};
    default:               st_d <= 32'd0;
    endcase
wire st_w_dcr = st_we && st_a[13:8] == 6'h05;

ppc403_core #(.PVR(32'h0020_1400)) u_cpu (
    .clk, .reset, .ce(ce_cpu), .tb_tick(tick66 && ce && tb_en && !halt),
    .i_req, .i_addr, .i_a31, .i_ack, .i_rdata,
    .d_req, .d_we, .d_addr, .d_a31, .d_cop, .d_be, .d_wdata, .d_ack, .d_rdata,
    .iccr_o(iccr), .dccr_o(dccr), .dcwr_o(dcwr),
    .dcr_we(dcr_we_c), .dcr_re(dcr_re_c), .dcr_addr, .dcr_wdata, .dcr_rdata,
    .ext_irq, .int_irq,
    .dbg_exec(dbg_exec_c), .dbg_pc, .dbg_ir, .dbg_sel(halted ? st_a[5:0] : dbg_sel), .dbg_val, .dbg_we, .dbg_wsel, .dbg_wdata
);
// an instruction starts only in a clock the CPU is enabled (the core's dbg_exec is not gated)
assign dbg_exec = dbg_exec_c && ce_cpu;
assign ext_irq = {ata_irq, 3'b000, gcu_irq} | irq_force;
// the core's line_bits: [2] SPU receive (EXISR bit 4, MAME's PPC4XX_IRQ_BIT_SPUR), [1] SPU transmit,
// [8:5] DMA channels 0-3 high to low (PPC4XX_IRQ_BIT_DMA0 is bit 8)
assign int_irq = {dma_irq[0], dma_irq[1], dma_irq[2], dma_irq[3], 2'b00, spu_irq_rx, spu_irq_tx, 1'b0};
// the DCRs neither the core nor the DMA holds (bank registers and the rest): kept and read back, as
// MAME's m_dcr array (ppccom.cpp:2512-2518)
logic [31:0] dcr_q;
sharc2_lutram #(.AW(8), .DW(32)) u_dcr (
    .clk, .we((ce_cpu && dcr_we_c && !dma_hit) || st_w_dcr), .wa(st_w_dcr ? st_a[7:0] : dcr_addr[7:0]),
    .wd(st_w_dcr ? st_wd : dcr_wdata), .ra(st_hold ? st_a[7:0] : dcr_addr[7:0]), .rd(dcr_q)
);
assign dcr_rdata = dma_hit ? dma_rdata : dcr_q;

logic         u_req, u_we, u_ack;
logic [30:0]  u_addr;
logic [3:0]   u_be;
logic [31:0]  u_wdata, u_rdata;

fb_ppc_mem u_mem (
    .clk, .reset, .ce(ce_cpu), .flush(halted), .flushed(dc_flushed),
    .i_req, .i_addr, .i_a31, .i_ack, .i_rdata,
    .d_req, .d_we, .d_addr, .d_a31, .d_be, .d_wdata, .d_cop, .d_ack, .d_rdata,
    .iccr, .dccr, .dcwr,
    .c_req, .c_we, .c_addr, .c_wdata, .c_ack, .c_rdata,
    .u_req, .u_we, .u_addr, .u_be, .u_wdata, .u_ack, .u_rdata
);

logic         g_we, g_port, g_ready, dma_port;
logic [31:0]  g_data;
logic         b_req, b_we, b_ack;
logic [30:0]  b_addr;
logic [3:0]   b_be;
logic [31:0]  b_wdata, b_rdata;

fb_ppc_dma u_dma (
    .clk, .reset, .dcr_we(ce_cpu && dcr_we_c), .dcr_addr, .dcr_wdata, .dcr_hit(dma_hit), .dcr_rdata(dma_rdata),
    .busy(dma_busy), .dport(dma_port), .irq(dma_irq), .bad(dma_bad),
    .m_req, .m_addr, .m_ack, .m_rdata,
    .g_we, .g_port, .g_data, .g_ready(g_ready && bs == B_IDLE),
    .b_req, .b_we, .b_addr, .b_be, .b_wdata, .b_ack, .b_rdata,
    .st_a(st_a[7:0]), .st_d(st_dma), .st_we(st_we && st_a[13:8] == 6'h04), .st_wd
);

// ---------------------------------------------------------------- the bus
typedef enum logic [4:0] {
    D_RAM, D_BIOS, D_SPU, D_XIRQW, D_XIRQR, D_CAB, D_SENS, D_YMZ, D_CTRL, D_IN, D_FLASH, D_RTC,
    D_XRAM, D_GCU, D_ATA0, D_ATA1, D_UART, D_NONE
} dev_t;

function automatic dev_t decode(input logic [30:0] a);
    if (a[30:25] == 6'd0) return D_RAM;
    if (a[30:19] == 12'hFFF) return D_BIOS;
    if (a[30:4] == 27'h400_0000) return D_SPU;
    if (a[30:2] == 29'h1C00_1800) return D_XIRQW;              // 0x70006000
    if (a[30:2] == 29'h1C00_2800) return D_XIRQR;              // 0x7000A000
    if (a[30:5] == 26'h3E8_0010) return D_CAB;                 // 0x7D000200-21F
    if (a[30:5] == 26'h3E8_001A) return D_SENS;                // 0x7D000340-35F
    if (a[30:1] == 30'h3E80_0200) return D_YMZ;                // 0x7D000400-401
    if (a[30:1] == 30'h3E80_0280) return D_CTRL;               // 0x7D000500-501
    if (a[30:2] == 29'h1F40_0200) return D_IN;                 // 0x7D000800-803
    if (a[30:21] == 10'h3EA || a[30:21] == 10'h3EC || a[30:21] == 10'h3ED) return D_FLASH;
    if (a[30:6] == 25'h1F8_0000) return D_RTC;                 // 0x7E000000-03F
    if (a[30:6] == 25'h1F8_0004) return D_XRAM;                // 0x7E000100-13F
    if (a[30:8] == 23'h7E_8000) return D_GCU;                  // 0x7E800000-0FF
    if (a[30:4] == 27'h7FE_0000) return D_ATA0;
    if (a[30:4] == 27'h7FE_8000) return D_ATA1;
    if (a[30:4] == 27'h7DC_0000) return D_UART;
    return D_NONE;
endfunction

typedef enum logic [2:0] { B_IDLE, B_GO, B_LANE, B_WAIT, B_DONE } bs_t;
bs_t         bs;
logic        bm;                         // the master: 0 CPU, 1 DMA
logic        r_we;
logic [30:0] r_addr;
logic [3:0]  r_be, r_left;
logic [31:0] r_wdata, r_rdata;
dev_t        r_dev;
logic [1:0]  r_lane;

assign u_ack = bs == B_DONE && !bm;
assign b_ack = bs == B_DONE && bm;
assign u_rdata = r_rdata;
assign b_rdata = r_rdata;

// byte and halfword devices: the lane in hand
wire        byte_dev = r_dev == D_SPU || r_dev == D_YMZ || r_dev == D_CTRL || r_dev == D_IN ||
                       r_dev == D_FLASH || r_dev == D_RTC || r_dev == D_XRAM || r_dev == D_XIRQW || r_dev == D_XIRQR ||
                       r_dev == D_UART;
wire [30:0] l_addr = {r_addr[30:2], r_lane};
wire [7:0]  l_wd = r_wdata[31 - 8*r_lane -: 8];

// device strobes for the lane in hand (one clock, B_LANE) and their answers
logic       ln_go;                       // B_LANE's first clock
logic       spu_req, rtc_req, ymz_req, fl_req, gcu_req, uart_req;
logic [7:0] spu_q, rtc_q, ymz_q, fl_q, uart_q;
logic       ymz_ack, fl_ack, gcu_ack, ata_req, ata_ack, ata_irq, ata_bad;
logic [15:0] ata_q;
logic [31:0] gcu_q;

// the extend board and the small registers
logic [7:0] xirq_en, xirq_act;

always_ff @(posedge clk) begin
    mon_v <= 1'b0;
    ln_go <= 1'b0;
    case (bs)
    B_IDLE:
        if (b_req || u_req) begin
            bm <= b_req;
            r_we <= b_req ? b_we : u_we;
            r_addr <= b_req ? b_addr : u_addr;
            r_be <= b_req ? b_be : u_be;
            r_left <= b_req ? b_be : u_be;
            r_wdata <= b_req ? b_wdata : u_wdata;
            r_dev <= decode(b_req ? b_addr : u_addr);
            r_rdata <= 32'h0;
            bs <= B_GO;
        end
    B_GO: begin
        case (r_dev)
        D_RAM, D_BIOS: if (r_dev == D_BIOS && r_we) bs <= B_DONE; else bs <= B_WAIT;
        D_CAB: begin r_rdata <= (r_addr[4:2] == 3'd0) ? {cabinet_info, 28'h0} : 32'h0; bs <= B_DONE; end
        D_SENS: begin
            // halfwords: offset = (address - 0x7D000340) / 2
            r_rdata <= {(r_addr[4:3] == 2'd0) ? sensor[{r_addr[2], 1'b0}] | 16'h0100 : 16'h0,
                        (r_addr[4:3] == 2'd0) ? sensor[{r_addr[2], 1'b1}] | 16'h0100 : 16'h0};
            bs <= B_DONE;
        end
        D_GCU: bs <= B_WAIT;
        D_NONE: bs <= B_DONE;
        D_ATA0, D_ATA1: begin            // halfword devices: lane 0 the high half, 2 the low
            r_lane <= (r_left[3:2] != 2'b00) ? 2'd0 : 2'd2;
            ln_go <= 1'b1;
            bs <= B_LANE;
        end
        default: begin                   // byte devices: the first enabled lane
            r_lane <= r_left[3] ? 2'd0 : r_left[2] ? 2'd1 : r_left[1] ? 2'd2 : 2'd3;
            ln_go <= 1'b1;
            bs <= B_LANE;
        end
        endcase
    end
    B_LANE: begin
        logic       done;
        logic [7:0] q;
        done = 1'b0; q = 8'h00;
        case (r_dev)
        D_SPU: if (!ln_go) begin done = 1'b1; q = spu_q; end
        D_UART: if (!ln_go) begin done = 1'b1; q = uart_q; end
        D_RTC, D_XRAM: if (!ln_go) begin done = 1'b1; q = rtc_q; end
        D_YMZ: if (ymz_ack) begin done = 1'b1; q = ymz_q; end
        D_FLASH: if (fl_ack) begin done = 1'b1; q = fl_q; end
        D_CTRL: begin done = 1'b1; if (r_we) control <= l_wd; end
        D_IN: begin
            done = 1'b1;
            q = (r_lane == 2'd0) ? in0 : (r_lane == 2'd1) ? in1 : (r_lane == 2'd2) ? in2 : in3;
        end
        D_XIRQW: begin
            done = 1'b1;
            if (r_we) begin xirq_act <= xirq_act & ~l_wd; xirq_en <= l_wd; end
        end
        D_XIRQR: begin done = 1'b1; q = ~xirq_act; end
        D_ATA0, D_ATA1: ;
        default: done = 1'b1;
        endcase
        if ((r_dev == D_ATA0 || r_dev == D_ATA1) && ata_ack) begin
            logic [3:0] left;
            if (!r_we) begin
                if (r_lane == 2'd0) r_rdata[31:16] <= {ata_q[7:0], ata_q[15:8]};
                else r_rdata[15:0] <= {ata_q[7:0], ata_q[15:8]};
            end
            left = r_left & ((r_lane == 2'd0) ? 4'b0011 : 4'b1100);
            r_left <= left;
            if (left == 4'd0) bs <= B_DONE;
            else begin r_lane <= 2'd2; ln_go <= 1'b1; end
        end else if (done) begin
            logic [3:0] left;
            if (!r_we) r_rdata[31 - 8*r_lane -: 8] <= q;
            left = r_left & ~(4'b1000 >> r_lane);
            r_left <= left;
            if (left == 4'd0) bs <= B_DONE;
            else begin
                r_lane <= left[3] ? 2'd0 : left[2] ? 2'd1 : left[1] ? 2'd2 : 2'd3;
                ln_go <= 1'b1;
            end
        end
    end
    B_WAIT:
        case (r_dev)
        D_RAM, D_BIOS: if (bw_ack) begin r_rdata <= w_rdata; bs <= B_DONE; end
        D_GCU: if (gcu_ack) begin r_rdata <= gcu_q; bs <= B_DONE; end
        default: bs <= B_DONE;
        endcase
    B_DONE: begin
        bs <= B_IDLE;
        if ((r_addr[30:4] == 27'h400_0000 || (r_addr[30:28] == 3'd7 && r_addr[30:19] != 12'hFFF))) begin
            mon_v <= 1'b1; mon_we <= r_we; mon_addr <= {r_addr[30:2], 2'b00};
            mon_mask <= {{8{r_be[3]}}, {8{r_be[2]}}, {8{r_be[1]}}, {8{r_be[0]}}};
            mon_data <= (r_we ? r_wdata : r_rdata) & {{8{r_be[3]}}, {8{r_be[2]}}, {8{r_be[1]}}, {8{r_be[0]}}};
        end
    end
    default: bs <= B_IDLE;
    endcase
    // the DMA's direct writes to the GCU, as the taps see a write of the port's register
    if (g_we) begin
        mon_v <= 1'b1; mon_we <= 1'b1; mon_addr <= g_port ? 31'h7E80_0074 : 31'h7E80_0070;
        mon_mask <= 32'hFFFF_FFFF; mon_data <= g_data;
    end
    if (reset) begin
        bs <= B_IDLE; control <= 8'h00; xirq_en <= 8'h3F; xirq_act <= 8'h00;
    end
end

wire lane_go = bs == B_LANE && ln_go;
assign spu_req = lane_go && r_dev == D_SPU;
assign rtc_req = lane_go && (r_dev == D_RTC || r_dev == D_XRAM);
assign ymz_req = bs == B_LANE && r_dev == D_YMZ && !ymz_ack;
assign fl_req  = bs == B_LANE && r_dev == D_FLASH && !fl_ack;
assign gcu_req = bs == B_WAIT && r_dev == D_GCU && !gcu_ack;

assign ata_req = bs == B_LANE && (r_dev == D_ATA0 || r_dev == D_ATA1) && !ata_ack;
assign uart_req = lane_go && r_dev == D_UART;

// ---------------------------------------------------------------- the SDRAM word port
// the bus (work RAM, BIOS) or the flash chips, held from request to acknowledge, the bus first
logic        bw_req, bw_ack, fw_req, fw_we, fw_ack;
logic [26:2] fw_addr;
logic [3:0]  fw_be;
logic [31:0] fw_wdata;
assign bw_req = bs == B_WAIT && (r_dev == D_RAM || r_dev == D_BIOS) && !bw_ack;
logic wg_v, wg_f;
wire  w_f = wg_v ? wg_f : !bw_req;
assign w_req   = w_f ? fw_req : bw_req;
assign w_we    = w_f ? fw_we : r_we;
assign w_addr  = w_f ? fw_addr : (r_dev == D_BIOS ? {8'h50, r_addr[18:2]} : {2'b00, r_addr[24:2]});
assign w_be    = w_f ? fw_be : r_be;
assign w_wdata = w_f ? fw_wdata : r_wdata;
always_ff @(posedge clk) begin
    bw_ack <= w_ack && !w_f;
    if (w_req && !w_ack) begin wg_v <= 1'b1; wg_f <= w_f; end
    if (w_ack) wg_v <= 1'b0;
    if (reset) begin wg_v <= 1'b0; bw_ack <= 1'b0; end
end
assign fw_ack = w_ack && w_f;
assign nv_wr  = (rtc_req && r_we) || (fw_req && fw_we && fw_ack);

// ---------------------------------------------------------------- devices
fb_pc16552 u_uart (
    .clk, .reset, .req(uart_req), .we(r_we), .addr(l_addr[3:0]), .wdata(l_wd), .rdata(uart_q),
    .st_a(st_a[4:0]), .st_d(st_uart), .st_we(st_we && st_a[13:5] == 9'h01A), .st_wd
);

fb_spu u_spu (
    .clk, .reset, .tick66, .iocr_b1(1'b0),
    .req(spu_req), .we(r_we), .addr(l_addr[3:0]), .wdata(l_wd), .rdata(spu_q),
    .irq_rx(spu_irq_rx), .irq_tx(spu_irq_tx), .bad(spu_bad),
    .ld_we(dg_we), .ld_addr(dg_addr), .ld_data(dg_data),
    .st_a(st_a[6:0]), .st_d(st_spu), .st_we(st_we && st_a[13:7] == 7'h04), .st_wd
);

fb_rtc65271 u_rtc (
    .clk, .reset(por),
    .req(rtc_req), .we(r_we), .xram(r_dev == D_XRAM), .addr(l_addr[5:0]), .wdata(l_wd), .rdata(rtc_q),
    .nv_we(rtc_nv_we), .nv_addr(st_hold && st_rtcnv ? st_a[12:0] : rtc_nv_addr), .nv_wdata(rtc_nv_wdata),
    .nv_rdata(rtc_nv_rdata), .tm_set(rtc_set), .tm_bcd(rtc_time),
    .st_a(st_a[5:0]), .st_d(st_rtc), .st_we(st_we && st_a[13:6] == 8'h0A), .st_wd
);

logic        y_req, y_ack;
logic [21:0] y_addr;
logic [7:0]  y_rdata;

fb_flash u_flash (
    .clk, .reset,
    .c_req(fl_req), .c_we(r_we), .c_chip(l_addr[30:21] == 10'h3EA ? 2'd0 : l_addr[30:21] == 10'h3EC ? 2'd1 : 2'd2),
    .c_addr(l_addr[20:0]), .c_wdata(l_wd), .c_ack(fl_ack), .c_rdata(fl_q),
    .y_req, .y_addr, .y_ack, .y_rdata,
    .w_req(fw_req), .w_we(fw_we), .w_addr(fw_addr), .w_be(fw_be), .w_wdata(fw_wdata), .w_ack(fw_ack),
    .w_rdata, .bad(flash_bad),
    .st_a(st_a[5:0]), .st_d(st_fl), .st_we(st_we && st_a[13:6] == 8'h0C), .st_wd
);

logic signed [15:0] ymz_l, ymz_r, cd_l, cd_r;
fb_ymz280b u_ymz (
    .clk, .reset,
    .req(ymz_req), .we(r_we), .a0(l_addr[0]), .wdata(l_wd), .ack(ymz_ack), .rdata(ymz_q),
    .y_req, .y_addr, .y_ack, .y_rdata,
    .out_l(ymz_l), .out_r(ymz_r), .tick(),
    .reg_q(st_ymz), .reg_a(st_a[7:0])
);

fb_gcu_shell u_gcu (
    .clk, .reset,
    .req(gcu_req), .we(r_we), .addr({r_addr[7:2], 2'b00}), .be(r_be), .wdata(r_wdata),
    .ack(gcu_ack), .rdata(gcu_q),
    .dg_we(g_we), .dg_port(g_port), .dg_data(g_data), .dg_ready(g_ready),
    .vblank, .busy0(!dma_hold && dma_busy && !dma_port), .busy1(!dma_hold && dma_busy && dma_port), .irq(gcu_irq),
    .cmd_v(gcu_cmd_v), .cmd_port(gcu_cmd_port), .cmd(gcu_cmd),
    .m_read(vm_read), .m_write(vm_write), .m_addr(vm_addr), .m_burst(vm_burst), .m_be(vm_be),
    .m_wdata(vm_wdata), .m_be_hi(vm_be_hi), .m_wdata_hi(vm_wdata_hi), .m_waitn(vm_waitn),
    .m_rvalid(vm_rvalid), .m_rdata(vm_rdata), .m_rdata_hi(vm_rdata_hi), .gcu_idle,
    .crtc(gd_crtc), .ctrl_lo(gd_layer), .fr_alpha(gd_alpha), .fr_x(gd_x), .fr_y(gd_y), .fr_w(gd_w),
    .fr_h(gd_h), .fr_base(gd_base), .reg_6c(gd_6c),
    .st_a(st_a[5:0]), .st_d(st_gcu), .st_we(st_we && st_a[13:6] == 8'h0E), .st_wd
);

// the ATA interface: MAME's internal value is the bus halfword byte-swapped
wire [15:0] ata_wd = (r_lane == 2'd0) ? {r_wdata[23:16], r_wdata[31:24]} : {r_wdata[7:0], r_wdata[15:8]};
fb_ata u_ata (
    .clk, .reset, .por,
    .req(ata_req), .we(r_we), .cs1(r_dev == D_ATA1), .off({r_addr[3:2], r_lane[1]}), .wdata(ata_wd),
    .ack(ata_ack), .rdata(ata_q), .irq(ata_irq),
    .img_mounted, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_ack, .sd_buff_wr, .sd_buff_dout,
    .play_on(), .play_lba(), .cd_l, .cd_r, .check(ata_check), .check_key(ata_key),
    .st_a(st_a[7:0]), .st_d(st_ata), .st_we(st_we && st_a[13:8] == 6'd1), .st_wd,
    .lg_a(st_a[11:0]), .lg_d(st_ata_log), .bad(ata_bad)
);

assign bad = dma_bad || spu_bad || flash_bad || ata_bad;

// the speaker: YMZ280B outputs 1 and 0 to its left and right (firebeat.cpp:770-771), CD audio straight
function automatic logic signed [15:0] mix(input logic signed [15:0] a, b);
    logic signed [16:0] x;
    x = 17'(a) + 17'(b);
    return (x > 17'sd32767) ? 16'sd32767 : (x < -17'sd32768) ? -16'sd32768 : x[15:0];
endfunction
always_ff @(posedge clk) begin
    aud_l <= mix(ymz_r, cd_l);
    aud_r <= mix(ymz_l, cd_r);
end

endmodule
