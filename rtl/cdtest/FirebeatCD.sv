// SPDX-License-Identifier: GPL-3.0-or-later

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

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

// Phase 0 item 2 (docs/ROADMAP.md): the CD path test core, revision FirebeatCD. The template's
// emu with two hps_io image slots, a cd_reader on each, and their counters on ISSP probes (the
// FirebeatCD_* fields in scripts/read_issp.tcl). The test picture is the template's.
//
// Probe A: slot 0 (program CD), probe B: slot 1 (audio CD); each, from bit 0:
//   requests[31:0] words[63:32] run_clocks[95:64] latency_sum[127:96] latency_max[159:128]
//   checksum[191:160] image_blocks[223:192] have_image[224]
// Probe F, sources: [0] clear, [1] run slot 0, [2] run slot 1, [3] random positions.
//   probe: frame counter [15:0], clk_sys MHz [23:16]

`include "build_id.v"
localparam CONF_STR = {
	"FirebeatCD;;",
	"-;",
	"S0,BINISOIMGCHD,Program CD;",
	"S1,BINISOIMGCHD,Audio CD;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire  [1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[2];
wire  [5:0] sd_blk_cnt[2];
wire  [1:0] sd_rd;
wire  [1:0] sd_ack;
wire [11:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(2), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

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

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

wire [1:0] col = 2'd0;

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
wire ce_pix;
wire hvcnt_atzero;
wire [7:0] video;

// Leave H/V sync always on. This stabilizes the video output while the core
// is in reset. This example releases the reset when H/V counters are at zero.
reg reset_core = 1;
always @(posedge clk_sys) begin
	if(reset) reset_core <= 1;
	else if(hvcnt_atzero) reset_core <= 0;
end

mycore mycore
(
	.clk(clk_sys),
	.reset(reset_core),

	.pal(1'b0),
	.scandouble(forced_scandoubler),

	.ce_pix(ce_pix),
	.hvcnt_atzero(hvcnt_atzero),

	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),

	.video(video)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;
assign VGA_G  = (!col || col == 2) ? video : 8'd0;
assign VGA_R  = (!col || col == 1) ? video : 8'd0;
assign VGA_B  = (!col || col == 3) ? video : 8'd0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

///////////////////////   CD PATH TEST   ///////////////////////////////

wire [7:0] ctl;
wire [31:0] r_req[2], r_words[2], r_run[2], r_lsum[2], r_lmax[2], r_sum[2], r_blocks[2];
wire        r_have[2];

genvar gs;
generate for (gs = 0; gs < 2; gs++) begin : g_slot
	cd_reader reader (
		.clk(clk_sys), .clear(ctl[0]), .run(ctl[1 + gs]), .rnd(ctl[3]),
		.mounted(img_mounted[gs]), .img_size(img_size),
		.sd_lba(sd_lba[gs]), .sd_blk_cnt(sd_blk_cnt[gs]), .sd_rd(sd_rd[gs]), .sd_ack(sd_ack[gs]),
		.sd_buff_wr(sd_buff_wr), .sd_buff_dout(sd_buff_dout),
		.have_image(r_have[gs]), .image_blocks(r_blocks[gs]), .requests(r_req[gs]), .words(r_words[gs]),
		.run_clocks(r_run[gs]), .latency_sum(r_lsum[gs]), .latency_max(r_lmax[gs]), .checksum(r_sum[gs])
	);
end endgenerate

reg [15:0] frames;
reg        vs_d;
always @(posedge clk_sys) begin
	vs_d <= VSync;
	if (VSync & ~vs_d) frames <= frames + 16'd1;
end

issp_probe #(.INSTANCE_ID("A"), .PROBE_W(225), .SOURCE_W(1)) u_probe_a (
	.clk(clk_sys),
	.probe({r_have[0], r_blocks[0], r_sum[0], r_lmax[0], r_lsum[0], r_run[0], r_words[0], r_req[0]}),
	.source()
);
issp_probe #(.INSTANCE_ID("B"), .PROBE_W(225), .SOURCE_W(1)) u_probe_b (
	.clk(clk_sys),
	.probe({r_have[1], r_blocks[1], r_sum[1], r_lmax[1], r_lsum[1], r_run[1], r_words[1], r_req[1]}),
	.source()
);
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(24), .SOURCE_W(8)) u_probe_f (
	.clk(clk_sys),
	.probe({8'd67, frames}),                  // clk_sys MHz, from rtl/pll (the first FirebeatCD builds ran at 20)
	.source(ctl)
);

endmodule
