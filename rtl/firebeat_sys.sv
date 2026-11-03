// SPDX-License-Identifier: GPL-3.0-or-later
//
// Everything below hps_io: the board (rtl/board/fb_board.sv), the SDRAM and DDR3 front ends, the
// download and the NVRAM file, the picture. Phase 1's bring-up pieces stay for the stp revision:
// with hold set the board is in reset and the read-back checker has the cache port; the test
// picture can be rewritten.
//
// SDRAM (rtl/mister/firebeat_sdram.sv, byte addresses of the module; ROADMAP memory plan):
//   0x0000000  work RAM, 32 MB
//   0x2000000  flash: 29F016A x 3 (main program, then the two sound chips), 6 MB
//   0x2800000  BIOS, 512 KB
//   0x2880000  POPN: the SPU's program ROM, 512 KB
//   0x4000000  POPN: the SPU's wave RAM, 32 MB (the 128 MB module)
// DDR3 (rtl/mister/hornet_ddr3.sv): VRAM, 32 MB at 0x30000000; the state dump (rtl/board/fb_dump.sv)
// at 0x34000000, written only while the board is stopped for it.
// The DS1991 dongle image (200 bytes) and the RTC65271's NVRAM are in the board's block RAM, loaded
// a byte at a time (two per hps_io write).
//
// Transfers are hps_io's 16-bit (WIDE) ones: ioctl_addr is a byte address, ioctl_dout[7:0] the
// file's even byte. SDRAM and block RAM hold big-endian halfwords, the even byte high.
//   index 0, the .mra's image: BIOS (ROM_LOAD16_WORD_SWAP, swapped by the .mra), then the
//            dongle at 0x80000; POPN: BIOS, the SPU's program (likewise swapped) at 0x80000,
//            the dongle at 0x100000
//   index 4, the NVRAM file, loaded after the image and saved on request: the three flash chips
//            (0x000000-0x5FFFFF), then the RTC in MAME's .nv format (0x600000-0x601037); an
//            RTC whose oscillator was never started (register A's DV bits 0, the core's reset
//            state, saved from a board that never ran a game) is skipped, leaving the preset
//
// The board is held in reset until the image has loaded whole (to the dongle; POPN, to the RTC
// preset's last word), and during every download; its CPU is
// paused during the NVRAM file's upload, which reads the flash from SDRAM and the RTC from the
// board.

module firebeat_sys #(
    parameter bit POPN = 1'b0               // the Pop'n Music board: fb_board's POPN, and the SPU
) (
    input  logic         clk,               // clk_sys, 66.667 MHz
    input  logic         clk_mem,           // 2 x clk, the SDRAM controller's
    input  logic         pll_locked,
    input  logic         reset,
    // sys's reset_out (emu RESET), which also resets the DDR3 port's bridge (sys/sysmem.sv): held
    // 20 ms after configuration and pulsed by the HPS's core resets. A read in flight across it
    // is lost, so the DDR3 masters reset with it and with nothing else (an OSD reset would cut a
    // transaction the bridge still expects).
    input  logic         hps_reset,

    input  logic         hold,              // the board in reset (bring-up)
    input  logic         pause,
    input  logic [64:0]  hps_rtc,           // hps_io RTC: BCD fields, [64] toggles on an update
    input  logic         dump_start,        // a pulse: dump the board's state, or release it after one
    input  logic         dump_on_err,       // dump at the slave drive's first CHECK CONDITION other than UNIT ATTENTION
    output logic         dump_busy,
    output logic         dump_held,         // stopped after a dump

    input  logic         ioctl_download,
    input  logic [15:0]  ioctl_index,
    input  logic         ioctl_wr,
    input  logic [26:0]  ioctl_addr,
    input  logic [15:0]  ioctl_dout,
    input  logic         ioctl_upload,
    input  logic         ioctl_rd,
    output logic [15:0]  ioctl_din,
    output logic         ioctl_wait,

    output logic [12:0]  SDRAM_A,
    inout  wire  [15:0]  SDRAM_DQ,
    output logic         SDRAM_DQML,
    output logic         SDRAM_DQMH,
    output logic [1:0]   SDRAM_BA,
    output logic         SDRAM_nCS,
    output logic         SDRAM_nWE,
    output logic         SDRAM_nRAS,
    output logic         SDRAM_nCAS,
    output logic         SDRAM_CKE,

    input  logic         DDRAM_BUSY,
    output logic [7:0]   DDRAM_BURSTCNT,
    output logic [28:0]  DDRAM_ADDR,
    input  logic [63:0]  DDRAM_DOUT,
    input  logic         DDRAM_DOUT_READY,
    output logic         DDRAM_RD,
    output logic [63:0]  DDRAM_DIN,
    output logic [7:0]   DDRAM_BE,
    output logic         DDRAM_WE,

    // the discs: hps_io image slots 0 (program CD) and 1 (audio CD; POPN the SPU's data DVD)
    input  logic [1:0]   img_mounted,
    input  logic [63:0]  img_size,
    output logic [31:0]  sd_lba [2],
    output logic [5:0]   sd_blk_cnt [2],
    output logic [1:0]   sd_rd,
    input  logic [1:0]   sd_ack,
    input  logic         sd_buff_wr,
    input  logic [15:0]  sd_buff_dout,

    input  logic [7:0]   in0, in1, in2, in3,
    input  logic [15:0]  sensor [4],
    input  logic [3:0]   cabinet_info,

    output logic         ce_pix,
    output logic [7:0]   vid_r, vid_g, vid_b,
    output logic         vid_hs, vid_vs, vid_hb, vid_vb,

    // bring-up (the stp revision's probes)
    input  logic         chk_start,         // a read-back pass: SDRAM by chk_sel, and both block RAMs
    input  logic         chk_sel,           // 0 the BIOS, 1 the flash
    input  logic         pat_start,         // rewrite the test picture
    input  logic         pat_variant,       // ... inverted
    input  logic         test_pic,          // show it instead of the GCU's display
    output logic         chk_busy,
    output logic [31:0]  chk_sum,
    output logic [22:0]  chk_lines,
    output logic [31:0]  chk_lat_sum,
    output logic [7:0]   chk_lat_max,
    output logic [15:0]  scan_late,
    output logic         pat_done,
    output logic [15:0]  dl_kb,            // KB written by downloads since the last clear
    // the board, for probes
    output logic [31:0]  brd_pc,
    output logic         brd_bad,
    output logic         brd_reset,
    output logic signed [15:0] aud_l, aud_r,
    output logic         nv_wr           // fb_board: the NVRAM file is stale
);

localparam logic [26:0] FLASH_BASE = 27'h2000000;
localparam logic [26:0] BIOS_BASE  = 27'h2800000;
localparam logic [26:0] SPU_BASE   = 27'h2880000;

// ------------------------------------------------------------------------------------------
// transfers
// ------------------------------------------------------------------------------------------

wire img_dl = ioctl_download && ioctl_index == 16'd0;
wire nv_xfr = ioctl_index == 16'd4;
wire nv_dl  = ioctl_download && nv_xfr;
wire nv_up  = ioctl_upload && nv_xfr;
wire nv_rtc = ioctl_addr >= 27'h600000 && ioctl_addr < 27'h601038;
// the file's RTC, unless its first word's register A (the odd byte) has DV 000
logic nv_rtc_skip;
wire nv_rtc_ld = nv_rtc && !(ioctl_addr == 27'h600000 ? ioctl_dout[14:12] == 3'd0 : nv_rtc_skip);
always_ff @(posedge clk) if (ioctl_wr && nv_dl && ioctl_addr == 27'h600000) nv_rtc_skip <= ioctl_dout[14:12] == 3'd0;
wire dg_hit = ioctl_addr[26:8] == (POPN ? 19'h01000 : 19'h00800);   // 0x80000 (POPN 0x100000), 256 bytes
wire sp_hit = POPN && ioctl_addr[26:19] == 8'd1;                    // 0x80000-0xFFFFF
// POPN: the set's RTC preset at 0x102000, the RTC's NVRAM until the NVRAM file (index 4) replaces it
wire rt_hit = POPN && ioctl_addr[26:13] == 14'h81 && ioctl_addr[12:0] < 13'h1038;

wire [15:0] hw_be = {ioctl_dout[7:0], ioctl_dout[15:8]};  // big-endian halfword

logic        d_we;
logic [26:1] d_addr;
logic [15:0] d_din;
wire         d_ready;

// the board's byte loads: the even byte with the write, the odd one the clock after
logic        dg_we, rtc_nv_we, b2_v, b2_dg;
logic [12:0] b2_a;
logic [7:0]  b2_d;

always_ff @(posedge clk) begin
    if (d_we && d_ready) d_we <= 1'b0;
    b2_v <= 1'b0;
    if (ioctl_wr && img_dl) begin
        if (ioctl_addr < 27'h80000) begin
            d_we <= 1'b1; d_addr <= BIOS_BASE[26:1] + ioctl_addr[26:1]; d_din <= hw_be;
        end else if (sp_hit) begin
            d_we <= 1'b1; d_addr <= {SPU_BASE[26:19], ioctl_addr[18:1]}; d_din <= hw_be;
        end else if (dg_hit) begin
            b2_v <= 1'b1; b2_dg <= 1'b1; b2_a <= {5'd0, ioctl_addr[7:1], 1'b1}; b2_d <= ioctl_dout[15:8];
        end else if (rt_hit) begin
            b2_v <= 1'b1; b2_dg <= 1'b0; b2_a <= {ioctl_addr[12:1], 1'b1}; b2_d <= ioctl_dout[15:8];
        end
    end
    if (ioctl_wr && nv_dl) begin
        if (ioctl_addr < 27'h600000) begin
            d_we <= 1'b1; d_addr <= FLASH_BASE[26:1] + ioctl_addr[26:1]; d_din <= hw_be;
        end else if (nv_rtc_ld && ioctl_addr + 27'd1 < 27'h601038) begin
            b2_v <= 1'b1; b2_dg <= 1'b0; b2_a <= {ioctl_addr[12:1], 1'b1}; b2_d <= ioctl_dout[15:8];
        end
    end
    if (!pll_locked) begin d_we <= 1'b0; b2_v <= 1'b0; end
end

assign dg_we = (ioctl_wr && img_dl && dg_hit) || (b2_v && b2_dg);
assign rtc_nv_we = (ioctl_wr && ((nv_dl && nv_rtc_ld) || (img_dl && rt_hit))) || (b2_v && !b2_dg);
wire [12:0] ld_a = b2_v ? b2_a : ioctl_addr[12:0];
wire [7:0]  ld_d = b2_v ? b2_d : ioctl_dout[7:0];

// the NVRAM file's upload: a flash halfword through the word port, an RTC one a byte at a time
// from the board (its address held two clocks a byte: the extended RAM answers a clock late)
logic        u_w_req, u_w_ack;
logic [26:2] u_w_addr;
logic [31:0] u_w_rdata;
logic        up_pend, up_half;
logic [2:0]  up_rs;                     // the RTC's bytes: 1-2 the even one, 3-4 the odd
logic [12:0] up_ra;
logic [7:0]  up_lo, rtc_nv_rdata;
wire  [12:0] up_nva = up_ra + {12'd0, up_rs[2] || up_rs == 3'd3};

always_ff @(posedge clk) begin
    if (ioctl_rd && nv_up) begin
        up_pend <= 1'b1;
        up_half <= ioctl_addr[1];
        if (nv_rtc) begin
            up_rs <= 3'd1; up_ra <= ioctl_addr[12:0];
        end else begin
            u_w_req <= 1'b1;
            u_w_addr <= FLASH_BASE[26:2] + ioctl_addr[26:2];
        end
    end
    if (up_rs != 3'd0) begin
        up_rs <= (up_rs == 3'd4) ? 3'd0 : up_rs + 3'd1;
        if (up_rs == 3'd2) up_lo <= rtc_nv_rdata;
        if (up_rs == 3'd4) begin
            up_pend <= 1'b0;
            ioctl_din <= {(up_ra + 13'd1 < 13'h1038) ? rtc_nv_rdata : 8'h00, up_lo};
        end
    end
    if (u_w_req && u_w_ack) begin
        u_w_req <= 1'b0;
        up_pend <= 1'b0;
        ioctl_din <= up_half ? {u_w_rdata[7:0], u_w_rdata[15:8]} : {u_w_rdata[23:16], u_w_rdata[31:24]};
    end
    if (!pll_locked) begin u_w_req <= 1'b0; up_pend <= 1'b0; up_rs <= 3'd0; end
end

assign ioctl_wait = d_we || up_pend || (ioctl_rd && nv_up);
wire [12:0] rtc_nv_addr = nv_up ? up_nva : ld_a;

// download size, in KB
logic [9:0] dl_b;
always_ff @(posedge clk) begin
    if (ioctl_wr && ioctl_download) begin
        dl_b <= dl_b + 10'd2;
        if (dl_b == 10'h3FE && dl_kb != 16'hFFFF) dl_kb <= dl_kb + 16'd1;
    end
    if (chk_start && !chk_busy) begin dl_b <= 10'd0; dl_kb <= 16'd0; end
end

// ------------------------------------------------------------------------------------------
// read-back
// ------------------------------------------------------------------------------------------

logic         c_req, c_ack, k_req;
logic [26:4]  c_addr, k_addr;
logic [127:0] c_rdata;

mem_check u_check (
    .clk, .reset(!pll_locked), .start(chk_start),
    .base(chk_sel ? FLASH_BASE[26:4] : BIOS_BASE[26:4]),
    .lines(chk_sel ? 23'h60000 : 23'h8000),
    .c_req(k_req), .c_addr(k_addr), .c_ack(c_ack && hold), .c_rdata,
    .busy(chk_busy), .sum(chk_sum), .done_lines(chk_lines), .lat_sum(chk_lat_sum), .lat_max(chk_lat_max)
);

// ------------------------------------------------------------------------------------------
// the board
// ------------------------------------------------------------------------------------------

logic         c_we, b_c_req, b_c_we;
logic [26:4]  b_c_addr;
logic [127:0] c_wdata;
logic         m_req, m_ack;
logic [26:5]  m_addr;
logic [255:0] m_rdata;
logic         w_req, w_we, w_ack, b_w_req, b_w_we, b_w_ack;
logic [26:2]  w_addr, b_w_addr;
logic [3:0]   w_be, b_w_be;
logic [31:0]  w_wdata, w_rdata, b_w_wdata;
logic         vm_read, vm_write, vm_waitn, vm_rvalid;
logic [31:0]  vm_addr, vm_wdata, vm_wdata_hi;
logic [10:0]  vm_burst;
logic [3:0]   vm_be, vm_be_hi;
logic         vblank;
logic [2:0][31:0] gd_crtc;
logic [15:0]  gd_layer, gd_6c;
logic [3:0][15:0] gd_alpha, gd_x, gd_y, gd_w, gd_h;
logic [3:0][31:0] gd_base;

// held until the image is in, and through every download. A set with a file missing loads short,
// and DDR3 may still hold another set's BIOS.
logic img_loaded, img_dl_q, img_end;
always_ff @(posedge clk) begin
    img_dl_q <= img_dl;
    if (img_dl && !img_dl_q) img_end <= 1'b0;
    if (ioctl_wr && img_dl && ioctl_addr >= (POPN ? 27'h103036 : 27'h80000)) img_end <= 1'b1;
    if (img_dl_q && !img_dl) img_loaded <= img_end;
    if (!pll_locked) img_loaded <= 1'b0;
end
assign brd_reset = reset || !pll_locked || hold || ioctl_download || !img_loaded;

// the HPS's time, set once, when the board first leaves reset (MAME sets it at start-up); the
// weekday as MAME's, 1 for Sunday
logic rtc_set, rtc_done, brd_reset_q;
always_ff @(posedge clk) begin
    brd_reset_q <= brd_reset;
    rtc_set <= brd_reset_q && !brd_reset && !rtc_done;
    if (rtc_set) rtc_done <= 1'b1;
    if (!pll_locked) rtc_done <= 1'b0;
end
wire [55:0] rtc_time = {hps_rtc[55:48] + 8'd1, hps_rtc[47:0]};

// ------------------------------------------------------------------------------------------
// the state dump
// ------------------------------------------------------------------------------------------

logic         x_halt, x_frozen, x_own, x_c_req, x_c_ack;
logic [26:4]  x_c_addr;
logic [13:0]  st_a;
logic [31:0]  st_d;
logic [1:0]   ata_check;
logic [3:0]   ata_key [2];
logic         err_armed, dump_on_err_q;

// armed when the switch goes on, spent by the dump it starts
always_ff @(posedge clk) begin
    dump_on_err_q <= dump_on_err;
    if (dump_on_err && !dump_on_err_q) err_armed <= 1'b1;
    if (!dump_on_err || x_halt) err_armed <= 1'b0;
end
wire x_start = dump_start || (err_armed && ata_check[1] && ata_key[1] != 4'h6);


logic signed [15:0] b_aud_l, b_aud_r;       // the board's sound; the popn revision's is the RF5C400
logic [31:0] b_sd_lba [2];
logic [5:0]  b_sd_blk_cnt [2];
logic [1:0]  b_sd_rd;
assign sd_lba[0] = b_sd_lba[0];
assign sd_blk_cnt[0] = b_sd_blk_cnt[0];
assign sd_lba[1] = POPN ? v_sd_lba : b_sd_lba[1];
assign sd_blk_cnt[1] = POPN ? v_sd_blk_cnt : b_sd_blk_cnt[1];
assign sd_rd = {POPN ? v_sd_rd : b_sd_rd[1], b_sd_rd[0]};

logic       dp_cs, dp_we, dp_irq;
logic [9:0] dp_addr;
logic [7:0] dp_wd, dp_rd;

fb_board #(.POPN(POPN)) u_board (
    .clk, .reset(brd_reset), .por(!pll_locked), .ce(!pause && !nv_up),
    .halt(x_halt), .frozen(x_frozen), .st_a, .st_d, .st_we(1'b0), .st_wd(32'd0), .ata_check, .ata_key,
    .dma_hold(1'b0), .tb_en(1'b1), .irq_force(5'd0), .dma_busy(),
    .c_req(b_c_req), .c_we(b_c_we), .c_addr(b_c_addr), .c_wdata, .c_ack(c_ack && !hold && !x_own), .c_rdata,
    .m_req, .m_addr, .m_ack, .m_rdata,
    .w_req(b_w_req), .w_we(b_w_we), .w_addr(b_w_addr), .w_be(b_w_be), .w_wdata(b_w_wdata),
    .w_ack(b_w_ack), .w_rdata,
    .vm_read, .vm_write, .vm_addr, .vm_burst, .vm_be, .vm_wdata, .vm_be_hi, .vm_wdata_hi,
    .vm_waitn, .vm_rvalid, .vm_rdata(d_rdata), .vm_rdata_hi(d_rdata_hi),
    .img_mounted, .img_size, .sd_lba(b_sd_lba), .sd_blk_cnt(b_sd_blk_cnt), .sd_rd(b_sd_rd),
    .sd_ack(POPN ? {1'b0, sd_ack[0]} : sd_ack), .sd_buff_wr, .sd_buff_dout,
    .vblank, .in0, .in1, .in2, .in3, .sensor, .cabinet_info,
    .dp_cs, .dp_we, .dp_addr, .dp_wd, .dp_rd, .dp_irq,
    .aud_l(b_aud_l), .aud_r(b_aud_r), .control(), .nv_wr,
    .dg_we, .dg_addr(ld_a[7:0]), .dg_data(ld_d),
    .rtc_nv_we, .rtc_nv_addr, .rtc_nv_wdata(ld_d), .rtc_nv_rdata,
    .rtc_set, .rtc_time,
    .gcu_cmd_v(), .gcu_cmd_port(), .gcu_cmd(),
    .gd_crtc, .gd_layer, .gd_alpha, .gd_x, .gd_y, .gd_w, .gd_h, .gd_base, .gd_6c,
    .mon_v(), .mon_we(), .mon_addr(), .mon_mask(), .mon_data(), .bad(brd_bad),
    .dbg_exec(), .dbg_pc(brd_pc), .dbg_ir(), .dbg_sel(6'd0), .dbg_val(),
    .dbg_we(1'b0), .dbg_wsel(6'd0), .dbg_wdata(32'd0)
);

// the cache port: the board's, the read-back checker's while the board is held, or the dump's
assign c_req  = hold ? k_req : x_own ? x_c_req : b_c_req;
assign c_we   = !hold && !x_own && b_c_we;
assign c_addr = hold ? k_addr : x_own ? x_c_addr : b_c_addr;
assign x_c_ack = c_ack && x_own && !hold;

// ------------------------------------------------------------------------------------------
// POPN: the SPU (rtl/spu/fb_spu68k.sv). Its program ROM and wave RAM are halfwords of the word
// port. Its ATA bus has one drive, the data DVD on hps_io slot 1 (fb_atapi, fb_dvd_slot), whose
// DMA writes wave RAM a word at a time (firebeat.cpp spu_dma_callback: bank + the DMA address,
// which then counts on). The RF5C400 answers 0 for now.
// ------------------------------------------------------------------------------------------

logic        s_w_req, s_w_we, s_w_ack;
logic        r_l_req, r_l_ack;              // the ROM cache's line fills (firebeat_sdram s)
logic [26:4] r_l_addr;
logic [127:0] r_l_rdata;
logic [26:2] s_w_addr;
logic [3:0]  s_w_be;
logic [31:0] s_w_wdata;
logic [31:0] v_sd_lba;
logic [5:0]  v_sd_blk_cnt;
logic        v_sd_rd;

generate if (POPN) begin : g_spu
logic        x_req, x_we, x_ack, x_ata, x_mem, x_rf, dev_ack;
logic [1:0]  x_be;
logic [2:0]  x_rgn;
logic [24:1] x_addr;
logic [15:0] x_wd, x_rd;
logic [31:0] dma_addr;
logic [1:0]  wave_bank;
logic        ata_irq, ata_us;
logic        dw_v, dw_ack;                  // a DMA word waiting for wave RAM
logic [15:0] dw_d;

fb_spu68k u_spu (
    .clk, .rst(brd_reset),
    .x_req, .x_we, .x_be, .x_rgn, .x_addr, .x_wd, .x_ack, .x_rd,
    .pp_cs(dp_cs), .pp_we(dp_we), .pp_addr(dp_addr), .pp_wd(dp_wd), .pp_rd(dp_rd), .ppc_irq(dp_irq),
    .ata_irq, .dsw(8'hFF), .leds(), .dma_addr, .dma_inc(dw_ack), .wave_bank,
    .tr_valid(), .tr_info(), .tr_data()
);

// x_rgn 0 the ROM (writes dropped), 1 the wave RAM, 2 and 3 the ATA's chip selects, 4 the RF5C400
logic x_rom;
assign x_rom = x_rgn == 3'd0 && !x_we;
assign x_mem = x_rgn == 3'd1;
assign x_ata = x_rgn == 3'd2 || x_rgn == 3'd3;
assign x_rf  = x_rgn == 3'd4;

// the program ROM through a cache of 512 16-byte lines, direct mapped: index ROM address [12:4],
// tag [18:13]. The ROM changes only with a download, which holds brd_reset; the valid bits are
// swept clear while it is held (zero at configuration).
logic [127:0] rc_data [512];
logic [6:0]   rc_tag [512];                 // { valid, tag }
logic [127:0] rc_q;
logic [6:0]   rc_tq;
logic [8:0]   rc_sweep;
logic [1:0]   rc_st;                        // 0 idle, 1 look, 2 fill
logic         rc_ack;
logic [15:0]  rc_hw;
wire  [8:0]   rc_i = x_addr[12:4];
function automatic logic [15:0] line_hw(input logic [127:0] l, input logic [2:0] h);
    logic [31:0] w;
    w = l[32 * h[2:1] +: 32];
    return h[0] ? w[15:0] : w[31:16];
endfunction
always_ff @(posedge clk) begin
    rc_q <= rc_data[rc_i];
    rc_tq <= rc_tag[rc_i];
    if (brd_reset) begin rc_tag[rc_sweep] <= 7'd0; rc_sweep <= rc_sweep + 9'd1; end
    else if (r_l_ack) begin rc_data[rc_i] <= r_l_rdata; rc_tag[rc_i] <= {1'b1, x_addr[18:13]}; end
end
always_ff @(posedge clk) begin
    rc_ack <= 1'b0;
    case (rc_st)
    2'd0: if (x_req && x_rom && !rc_ack) rc_st <= 2'd1;
    2'd1: if (rc_tq == {1'b1, x_addr[18:13]}) begin
              rc_ack <= 1'b1; rc_hw <= line_hw(rc_q, x_addr[3:1]); rc_st <= 2'd0;
          end else begin r_l_req <= 1'b1; r_l_addr <= {SPU_BASE[26:19], x_addr[18:4]}; rc_st <= 2'd2; end
    default: if (r_l_ack) begin
              r_l_req <= 1'b0; rc_ack <= 1'b1; rc_hw <= line_hw(r_l_rdata, x_addr[3:1]); rc_st <= 2'd0;
          end
    endcase
    if (brd_reset) begin rc_st <= 2'd0; r_l_req <= 1'b0; end
end

// the drive: a strobe (a register access or a DMA word), its answer the clock after, then a
// clock free, so strobes are three clocks apart; a pending register access goes first
logic        a_acc, a_dma, a_q, a_dq, a_ack, a_resp, dmarq;
logic [15:0] a_rd, a_q_rd;
wire         a_free = !a_acc && !a_dma && !a_q && !a_dq;
always_ff @(posedge clk) begin
    a_acc <= a_free && x_req && x_ata && !a_ack;
    a_dma <= a_free && !(x_req && x_ata && !a_ack) && dmarq && !dw_v && !dw_ack;
    a_q <= a_acc;
    a_dq <= a_dma;
    a_ack <= a_q;
    if (a_q) a_q_rd <= a_resp ? a_rd : 16'hFFFF;
    if (a_dq) begin dw_v <= 1'b1; dw_d <= a_rd; end
    if (dw_ack) dw_v <= 1'b0;
    if (brd_reset) begin a_acc <= 1'b0; a_dma <= 1'b0; a_q <= 1'b0; a_dq <= 1'b0; a_ack <= 1'b0; dw_v <= 1'b0; end
end

logic        rq, rq_done, bw_we, have, dnew;
logic [31:0] rq_lba, toc_start;
logic [9:0]  bw_a;
logic [15:0] bw_d;
logic [6:0]  ntrk, toc_a;

fb_atapi #(.CSEL(1'b0)) u_drv (
    .clk, .reset(brd_reset), .tick_us(ata_us),
    .acc(a_acc), .we(x_we), .cs1(x_rgn == 3'd3), .off(x_addr[3:1]), .wd(x_wd), .resp(a_resp), .rd(a_rd),
    .dma_acc(a_dma), .dmarq,
    .irq_o(ata_irq), .dasp_o(), .pdiag_o(), .dasp_i(1'b0), .pdiag_i(1'b0),
    .have_disc(have), .disc_new(dnew), .ntrk, .toc_a, .toc_start, .toc_audio(1'b0), .toc_ctl(4'h4),
    .rq, .rq_lba, .rq_half(), .rq_done, .bw_we, .bw_a, .bw_d,
    .play_on(), .play_lba(), .play_smp(), .play_tick(), .vol0(), .vol1(),
    .check(), .check_key(), .st_a(7'd0), .st_d(), .st_we(1'b0), .st_wd(32'd0), .bad()
);

fb_dvd_slot u_dvd (
    .clk, .reset(!pll_locked), .brd_reset,
    .mounted(img_mounted[1]), .img_size,
    .sd_lba(v_sd_lba), .sd_blk_cnt(v_sd_blk_cnt), .sd_rd(v_sd_rd), .sd_ack(sd_ack[1]),
    .sd_buff_wr, .sd_buff_dout,
    .have_disc(have), .disc_new(dnew), .ntrk, .toc_a, .toc_start,
    .rq, .rq_lba, .rq_done, .bw_we, .bw_a, .bw_d
);

// the drive's microsecond: 66.667 clocks, 66, 67, 67
logic [6:0] us_n;
logic [1:0] us_ph;
always_ff @(posedge clk) begin
    ata_us <= 1'b0;
    if (us_n == ((us_ph == 2'd0) ? 7'd65 : 7'd66)) begin
        us_n <= 7'd0; ata_us <= 1'b1; us_ph <= (us_ph == 2'd2) ? 2'd0 : us_ph + 2'd1;
    end else us_n <= us_n + 7'd1;
    if (brd_reset) begin us_n <= '0; us_ph <= '0; end
end

// the RF5C400: the 68000's 400000-400FFF, its samples from the wave RAM's 16M words
logic        rf_ack, rf_mreq, rf_mwe, rf_mack;
logic [15:0] rf_rd, rf_mwd;
logic [23:0] rf_maddr;
fb_rf5c400 u_rf (
    .clk, .reset(brd_reset),
    .req(x_req && x_rf), .we(x_we), .addr(x_addr[11:1]), .wd(x_wd), .ack(rf_ack), .rd(rf_rd),
    .m_req(rf_mreq), .m_we(rf_mwe), .m_addr(rf_maddr), .m_wd(rf_mwd), .m_ack(rf_mack),
    .m_rd(rf_maddr[0] ? w_rdata[15:0] : w_rdata[31:16]),
    .out_l(aud_l), .out_r(aud_r), .sample()
);

// the word port: the RF5C400's sample (32 words a 44.1 kHz sample at most, the one deadline),
// a DMA word or the 68000's wave RAM access, one at a time in that order
localparam logic [1:0] SW_CPU = 2'd0, SW_DMA = 2'd1, SW_RF = 2'd2;
logic        sw_busy;
logic [1:0]  sw_src;
wire  [23:0] dw_word = {wave_bank, 22'd0} + dma_addr[23:0];
always_ff @(posedge clk) begin
    if (!sw_busy) begin
        if (rf_mreq)             begin sw_busy <= 1'b1; sw_src <= SW_RF;  end
        else if (dw_v && !dw_ack) begin sw_busy <= 1'b1; sw_src <= SW_DMA; end
        else if (x_req && x_mem) begin sw_busy <= 1'b1; sw_src <= SW_CPU; end
    end else if (s_w_ack) sw_busy <= 1'b0;
    if (brd_reset) sw_busy <= 1'b0;
end
wire  [23:0] sw_word = sw_src == SW_DMA ? dw_word : rf_maddr;
assign dw_ack    = s_w_ack && sw_src == SW_DMA;
assign rf_mack   = s_w_ack && sw_src == SW_RF;
assign s_w_req   = sw_busy && (sw_src == SW_DMA ? dw_v : sw_src == SW_RF ? rf_mreq : x_req);
assign s_w_we    = sw_src == SW_DMA || (sw_src == SW_RF ? rf_mwe : x_we);
assign s_w_addr  = sw_src == SW_CPU ? {2'b10, x_addr[24:2]} : {2'b10, sw_word[23:1]};
assign s_w_be    = sw_src == SW_CPU ? (x_addr[1] ? {2'b00, x_be} : {x_be, 2'b00}) :
                   sw_word[0] ? 4'b0011 : 4'b1100;
assign s_w_wdata = sw_src == SW_DMA ? {dw_d, dw_d} : sw_src == SW_RF ? {rf_mwd, rf_mwd} : {x_wd, x_wd};

// the rest: ROM writes, answered the clock after
always_ff @(posedge clk) dev_ack <= x_req && !x_rom && !x_mem && !x_ata && !x_rf && !dev_ack;
assign x_ack = (s_w_ack && sw_src == SW_CPU) || a_ack || dev_ack || rc_ack || rf_ack;
assign x_rd  = rc_ack ? rc_hw : a_ack ? a_q_rd : rf_ack ? rf_rd : dev_ack ? 16'h0000 :
               x_addr[1] ? w_rdata[15:0] : w_rdata[31:16];
end else begin : g_no_spu
assign {s_w_req, s_w_we, s_w_addr, s_w_be, s_w_wdata, dp_rd, dp_irq, v_sd_lba, v_sd_blk_cnt, v_sd_rd,
        r_l_req, r_l_addr} = '0;
assign aud_l = b_aud_l;
assign aud_r = b_aud_r;
end endgenerate

// the word port: the upload's, the board's or the SPU's, a request at a time in that order
logic       w_busy;
logic [1:0] w_own;                      // 0 the board, 1 the upload, 2 the SPU
always_ff @(posedge clk) begin
    if (!w_busy) begin
        if (u_w_req) begin w_busy <= 1'b1; w_own <= 2'd1; end
        else if (b_w_req) begin w_busy <= 1'b1; w_own <= 2'd0; end
        else if (s_w_req) begin w_busy <= 1'b1; w_own <= 2'd2; end
    end else if (w_ack) w_busy <= 1'b0;
    if (!pll_locked) w_busy <= 1'b0;
end
assign w_req   = w_busy && (w_own == 2'd1 ? u_w_req : w_own == 2'd2 ? s_w_req : b_w_req);
assign w_we    = w_own == 2'd0 ? b_w_we : w_own == 2'd2 && s_w_we;
assign w_addr  = w_own == 2'd1 ? u_w_addr : w_own == 2'd2 ? s_w_addr : b_w_addr;
assign w_be    = w_own == 2'd1 ? 4'hF : w_own == 2'd2 ? s_w_be : b_w_be;
assign w_wdata = w_own == 2'd2 ? s_w_wdata : b_w_wdata;
assign b_w_ack = w_ack && w_busy && w_own == 2'd0;
assign u_w_ack = w_ack && w_busy && w_own == 2'd1;
assign s_w_ack = w_ack && w_busy && w_own == 2'd2;
assign u_w_rdata = w_rdata;

// ------------------------------------------------------------------------------------------
// SDRAM
// ------------------------------------------------------------------------------------------

firebeat_sdram u_sdram (
    .clk, .clk_mem, .init(!pll_locked), .reset(!pll_locked),
    .SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
    .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE,
    .c_req, .c_we, .c_addr, .c_wdata, .c_ack, .c_rdata,
    .m_req, .m_addr, .m_ack, .m_rdata,
    .w_req, .w_we, .w_addr, .w_be, .w_wdata, .w_ack, .w_rdata,
    .s_req(r_l_req), .s_addr(r_l_addr), .s_ack(r_l_ack), .s_rdata(r_l_rdata),
    .d_we, .d_addr, .d_din, .d_ready
);

// ------------------------------------------------------------------------------------------
// DDR3: master 0 the GCU, 1 the test picture's writes, 2 the state dump, 3 scan-out (served first)
// ------------------------------------------------------------------------------------------

logic [1:0] hps_rst_s = 2'b11;
always_ff @(posedge clk) hps_rst_s <= {hps_rst_s[0], hps_reset};
wire ddr_rst = !pll_locked || hps_rst_s[1];

logic [3:0]       d_read, d_write, d_waitn, d_rvalid;
logic [3:0][31:0] d_maddr, d_wdata, d_wdata_hi;
logic [3:0][3:0]  d_be, d_be_hi;
logic [3:0][10:0] d_burst;
logic [31:0]      d_rdata, d_rdata_hi;

// PRI 0, the GCU; Quartus elaborates req[PRI] even when PRI is -1
hornet_ddr3 #(.N(4), .WIDE(4'b1111), .PRI(0)) u_ddr3 (
    .clk, .reset(ddr_rst), .drain(1'b0), .idle(),
    .m_read(d_read), .m_write(d_write), .m_addr(d_maddr), .m_burst(d_burst), .m_be(d_be),
    .m_wdata(d_wdata), .m_be_hi(d_be_hi), .m_wdata_hi(d_wdata_hi), .m_waitn(d_waitn),
    .m_rvalid(d_rvalid), .m_rready(4'b1111), .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
    .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .dbg(), .dbg_cmd()
);

fb_dump u_dump (
    .clk, .reset(ddr_rst), .abort(brd_reset), .start(x_start), .halt(x_halt), .frozen(x_frozen),
    .port_free(!b_c_req && sd_rd == 2'b00), .busy(dump_busy), .own(x_own), .st_a, .st_d,
    .c_req(x_c_req), .c_addr(x_c_addr), .c_ack(x_c_ack), .c_rdata,
    .m_write(d_write[2]), .m_addr(d_maddr[2]), .m_burst(d_burst[2]), .m_wdata(d_wdata[2]),
    .m_wdata_hi(d_wdata_hi[2]), .m_waitn(d_waitn[2])
);
assign dump_held = x_halt && !dump_busy;

assign d_read[0] = vm_read;
assign d_write[0] = vm_write;
assign d_maddr[0] = vm_addr;
assign d_burst[0] = vm_burst;
assign d_be[0] = vm_be;
assign d_be_hi[0] = vm_be_hi;
assign d_wdata[0] = vm_wdata;
assign d_wdata_hi[0] = vm_wdata_hi;
assign vm_waitn = d_waitn[0];
assign vm_rvalid = d_rvalid[0];
assign d_be[1] = 4'hF; assign d_be_hi[1] = 4'hF;
assign d_be[2] = 4'hF; assign d_be_hi[2] = 4'hF;
assign d_be[3] = 4'hF; assign d_be_hi[3] = 4'hF;
assign d_read[2] = 1'b0;

assign d_read[1] = 1'b0;
pattern_writer u_pat (
    .clk, .reset(ddr_rst), .start(pat_start), .variant(pat_variant), .auto(test_pic), .done(pat_done),
    .m_write(d_write[1]), .m_addr(d_maddr[1]), .m_burst(d_burst[1]), .m_wdata(d_wdata[1]),
    .m_wdata_hi(d_wdata_hi[1]), .m_waitn(d_waitn[1])
);

// ------------------------------------------------------------------------------------------
// video
// ------------------------------------------------------------------------------------------

assign d_write[3] = 1'b0;
assign d_wdata[3] = 32'd0;
assign d_wdata_hi[3] = 32'd0;
fb_gcu_disp u_disp (
    .clk, .reset(ddr_rst), .test(test_pic),
    .crtc(gd_crtc), .layer(gd_layer), .fr_alpha(gd_alpha), .fr_x(gd_x), .fr_y(gd_y), .fr_w(gd_w),
    .fr_h(gd_h), .fr_base(gd_base), .reg_6c(gd_6c),
    .m_read(d_read[3]), .m_addr(d_maddr[3]), .m_burst(d_burst[3]), .m_waitn(d_waitn[3]),
    .m_rvalid(d_rvalid[3]), .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .ce_pix, .r(vid_r), .g(vid_g), .b(vid_b), .hs(vid_hs), .vs(vid_vs), .hb(vid_hb), .vb(vid_vb),
    .vblank, .late(scan_late)
);

endmodule
