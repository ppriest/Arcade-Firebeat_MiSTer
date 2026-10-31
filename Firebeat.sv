// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami Firebeat (ParaParaParadise) for MiSTer: rtl/firebeat_sys.sv on the DE10-nano.
//
// Clocks (rtl/pll, ROADMAP "Clocks"): clk_sys 66.667 MHz (the board, the picture at clk_sys/4,
// DDR3); clk_mem 133.333 MHz, the SDRAM controller's; SDRAM_CLK 133.333 MHz shifted 3750 ps.
// Discs: image slots 0 (program CD) and 1 (audio CD), CHDs served by MiSTer_Firebeat
// (scripts/main_mister).

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Firebeat;;",
	"-;",
	"SC0,CHDBINISOIMG,Program CD;",
	"SC1,CHDBINISOIMG,Audio CD;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"H0P1,Debug;",
	"P1T[64],Dump state / release;",
	"P1O[65],Dump on slave error,Off,On;",
	"-;",
	"R[0],Reset and close OSD;",
	"J1,Left,Right,Start,Coin,Test,Service,Pause;",
	"V,v",`BUILD_DATE
};

// the Debug page (WORKFLOW section 4): hidden when FB_RELEASE is defined
`ifdef FB_RELEASE
wire debug_hidden = 1'b1;
`else
wire debug_hidden = 1'b0;
`endif

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joy;
wire  [64:0] hps_rtc;

wire        ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
wire [26:0] ioctl_addr;
wire        nvram_save;

wire  [1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[2];
wire  [5:0] sd_blk_cnt[2];
wire  [1:0] sd_ack;
wire  [1:0] sd_rd;
wire [11:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(2), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, debug_hidden}),
	.joystick_0(joy),
	.RTC(hps_rtc),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(2'b00),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{16'd0, 16'd0}),
	.sd_buff_wr(sd_buff_wr),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);


///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_mem, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(SDRAM_CLK),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1];

///////////////////////   SYSTEM   ///////////////////////////////

wire [7:0]  issp_src;
wire        chk_busy, pat_done;
wire [31:0] chk_sum, chk_lat_sum, brd_pc;
wire [22:0] chk_lines;
wire [7:0]  chk_lat_max;
wire [15:0] scan_late, dl_kb;
wire        brd_bad, brd_reset, dump_busy, dump_held;
reg         dump_t_q;
always @(posedge clk_sys) dump_t_q <= status[64];

// IN0 (firebeat.cpp INPUT_PORTS ppp): active low; 0 Left, 1 Right, 2 Test, 3 Service, 4 Coin,
// 5 Start/OK; bit 6 unused high, bit 7 unused low
wire [7:0] in0 = {1'b0, 1'b1, ~joy[6], ~joy[7], ~joy[9], ~joy[8], ~joy[5], ~joy[4]};
reg  pause, joy10_q;
always @(posedge clk_sys) begin
	joy10_q <= joy[10];
	if (joy[10] && !joy10_q) pause <= ~pause;
	if (reset) pause <= 1'b0;
end
wire [15:0] sensor[4] = '{16'd0, 16'd0, 16'd0, 16'd0};
wire        vid_hb, vid_vb, vid_hs, vid_vs, ce_pix;
wire [7:0]  vid_r, vid_g, vid_b;

assign DDRAM_CLK = clk_sys;

firebeat_sys sys (
	.clk(clk_sys), .clk_mem, .pll_locked, .reset, .hps_reset(RESET),
	.hold(issp_src[6]), .pause, .hps_rtc,
	.dump_start(status[64] && !dump_t_q), .dump_on_err(status[65]), .dump_busy, .dump_held,
	.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout,
	.ioctl_upload, .ioctl_rd, .ioctl_din, .ioctl_wait,
	.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
	.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE,
	.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
	.DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
	.img_mounted, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_ack, .sd_buff_wr, .sd_buff_dout,
	.in0, .in1(8'hFF), .in2(8'hFF), .in3(8'hFF), .sensor, .cabinet_info(4'd8),
	.ce_pix, .vid_r, .vid_g, .vid_b, .vid_hs, .vid_vs, .vid_hb, .vid_vb,
	.chk_start(issp_src[1]), .chk_sel(issp_src[2]), .pat_start(issp_src[3]), .pat_variant(issp_src[4]),
	.test_pic(issp_src[7]),
	.chk_busy, .chk_sum, .chk_lines, .chk_lat_sum, .chk_lat_max,
	.scan_late, .pat_done, .dl_kb, .brd_pc, .brd_bad, .brd_reset
);

// the NVRAM file's save: the stp revision's probe F can request one
assign nvram_save = issp_src[5];

///////////////////////   VIDEO   ////////////////////////////////

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE = !(vid_hb || vid_vb);
assign VGA_HS = vid_hs;
assign VGA_VS = vid_vs;
assign VGA_R  = vid_r;
assign VGA_G  = vid_g;
assign VGA_B  = vid_b;

assign LED_USER = ioctl_download | ioctl_upload | dump_busy | dump_held;

///////////////////////   PROBES   ///////////////////////////////

`ifdef DEBUG_ISSP
// probe F (scripts/read_issp.tcl fields_F): bring-up. frame_50m is the last frame's length in
// CLK_50M clocks, which checks the PLL and the timing together (58.4877 Hz: 854,881).
// Sources: [0] clear the frame counter, [1] start a read-back pass (probe M), [2] its range
// (0 BIOS, 1 flash), [3] rewrite the test picture, [4] inverted, [5] request the NVRAM save,
// [6] hold the board in reset (needed for a read-back pass), [7] show the test picture instead
// of the GCU's display.
reg  [15:0] frames;
reg         vs_q;
always @(posedge clk_sys) begin
	vs_q <= vid_vs;
	if (vid_vs && !vs_q && frames != 16'hFFFF) frames <= frames + 1'd1;
	if (issp_src[0]) frames <= 16'd0;
end
reg  [2:0]  vs50;
reg  [23:0] cnt50, frame_50m;
always @(posedge CLK_50M) begin
	vs50 <= {vs50[1:0], vid_vs};
	cnt50 <= cnt50 + 1'd1;
	if (vs50[1] && !vs50[2]) begin frame_50m <= cnt50 + 1'd1; cnt50 <= 24'd0; end
end
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(92), .SOURCE_W(8)) u_probe_f (
	.clk(clk_sys),
	.probe({pll_locked, pat_done, chk_busy, ioctl_download, scan_late, dl_kb, frame_50m, frames}),
	.source(issp_src)
);
// probe M: the last read-back pass, and the board: its CPU's PC, a model's unsupported mode
issp_probe #(.INSTANCE_ID("M"), .PROBE_W(129), .SOURCE_W(1)) u_probe_m (
	.clk(clk_sys),
	.probe({brd_reset, brd_bad, brd_pc, chk_lat_max, chk_lat_sum, chk_lines, chk_sum}),
	.source()
);
`else
assign issp_src = 8'd0;
`endif

endmodule
