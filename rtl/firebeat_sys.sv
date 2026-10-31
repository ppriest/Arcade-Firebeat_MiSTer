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
// DDR3 (rtl/mister/hornet_ddr3.sv): VRAM, 32 MB at 0x30000000; the state dump (rtl/board/fb_dump.sv)
// at 0x34000000, written only while the board is stopped for it.
// The DS1991 dongle image (200 bytes) and the RTC65271's NVRAM are in the board's block RAM, loaded
// a byte at a time (two per hps_io write).
//
// Transfers are hps_io's 16-bit (WIDE) ones: ioctl_addr is a byte address, ioctl_dout[7:0] the
// file's even byte. SDRAM and block RAM hold big-endian halfwords, the even byte high.
//   index 0, the .mra's image: BIOS (ROM_LOAD16_WORD_SWAP, swapped by the .mra), then the
//            dongle at 0x80000
//   index 4, the NVRAM file, loaded after the image and saved on request: the three flash chips
//            (0x000000-0x5FFFFF), then the RTC in MAME's .nv format (0x600000-0x601037)
//
// The board is held in reset until the image has loaded, and during every download; its CPU is
// paused during the NVRAM file's upload, which reads the flash from SDRAM and the RTC from the
// board.

module firebeat_sys (
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

    // the discs: hps_io image slots 0 (program CD) and 1 (audio CD)
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
    output logic         brd_reset
);

localparam logic [26:0] FLASH_BASE = 27'h2000000;
localparam logic [26:0] BIOS_BASE  = 27'h2800000;

// ------------------------------------------------------------------------------------------
// transfers
// ------------------------------------------------------------------------------------------

wire img_dl = ioctl_download && ioctl_index == 16'd0;
wire nv_xfr = ioctl_index == 16'd4;
wire nv_dl  = ioctl_download && nv_xfr;
wire nv_up  = ioctl_upload && nv_xfr;
wire nv_rtc = ioctl_addr >= 27'h600000 && ioctl_addr < 27'h601038;
wire dg_hit = ioctl_addr[26:8] == 19'h00800;            // 0x80000-0x800FF

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
        end else if (dg_hit) begin
            b2_v <= 1'b1; b2_dg <= 1'b1; b2_a <= {5'd0, ioctl_addr[7:1], 1'b1}; b2_d <= ioctl_dout[15:8];
        end
    end
    if (ioctl_wr && nv_dl) begin
        if (ioctl_addr < 27'h600000) begin
            d_we <= 1'b1; d_addr <= FLASH_BASE[26:1] + ioctl_addr[26:1]; d_din <= hw_be;
        end else if (nv_rtc && ioctl_addr + 27'd1 < 27'h601038) begin
            b2_v <= 1'b1; b2_dg <= 1'b0; b2_a <= {ioctl_addr[12:1], 1'b1}; b2_d <= ioctl_dout[15:8];
        end
    end
    if (!pll_locked) begin d_we <= 1'b0; b2_v <= 1'b0; end
end

assign dg_we = (ioctl_wr && img_dl && dg_hit) || (b2_v && b2_dg);
assign rtc_nv_we = (ioctl_wr && nv_dl && nv_rtc) || (b2_v && !b2_dg);
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

// held until the image is in, and through every download
logic img_loaded, img_dl_q;
always_ff @(posedge clk) begin
    img_dl_q <= img_dl;
    if (img_dl_q && !img_dl) img_loaded <= 1'b1;
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


fb_board u_board (
    .clk, .reset(brd_reset), .por(!pll_locked), .ce(!pause && !nv_up),
    .halt(x_halt), .frozen(x_frozen), .st_a, .st_d, .st_we(1'b0), .st_wd(32'd0), .ata_check, .ata_key,
    .dma_hold(1'b0), .tb_en(1'b1), .irq_force(5'd0), .dma_busy(),
    .c_req(b_c_req), .c_we(b_c_we), .c_addr(b_c_addr), .c_wdata, .c_ack(c_ack && !hold && !x_own), .c_rdata,
    .m_req, .m_addr, .m_ack, .m_rdata,
    .w_req(b_w_req), .w_we(b_w_we), .w_addr(b_w_addr), .w_be(b_w_be), .w_wdata(b_w_wdata),
    .w_ack(b_w_ack), .w_rdata,
    .vm_read, .vm_write, .vm_addr, .vm_burst, .vm_be, .vm_wdata, .vm_be_hi, .vm_wdata_hi,
    .vm_waitn, .vm_rvalid, .vm_rdata(d_rdata), .vm_rdata_hi(d_rdata_hi),
    .img_mounted, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_ack, .sd_buff_wr, .sd_buff_dout,
    .vblank, .in0, .in1, .in2, .in3, .sensor, .cabinet_info, .control(),
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

// the word port: the board's or the upload's, a request at a time, the upload first
logic w_busy, w_own;                    // w_own: 1 the upload
always_ff @(posedge clk) begin
    if (!w_busy) begin
        if (u_w_req) begin w_busy <= 1'b1; w_own <= 1'b1; end
        else if (b_w_req) begin w_busy <= 1'b1; w_own <= 1'b0; end
    end else if (w_ack) w_busy <= 1'b0;
    if (!pll_locked) w_busy <= 1'b0;
end
assign w_req   = w_busy && (w_own ? u_w_req : b_w_req);
assign w_we    = !w_own && b_w_we;
assign w_addr  = w_own ? u_w_addr : b_w_addr;
assign w_be    = w_own ? 4'hF : b_w_be;
assign w_wdata = b_w_wdata;
assign b_w_ack = w_ack && w_busy && !w_own;
assign u_w_ack = w_ack && w_busy && w_own;
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
