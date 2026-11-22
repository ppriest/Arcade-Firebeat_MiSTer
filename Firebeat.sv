// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami Firebeat (ParaParaParadise; Pop'n Music in the Firebeat_popn revision, FB_POPN;
// Keyboardmania in Firebeat_kbm, FB_KBM) for MiSTer: rtl/firebeat_sys.sv on the DE10-nano.
//
// Clocks (rtl/pll, ROADMAP "Clocks"): clk_sys 66.667 MHz (the board, the picture at clk_sys/4,
// DDR3); clk_mem 133.333 MHz, the SDRAM controller's; SDRAM_CLK 133.333 MHz shifted 3750 ps.
// Discs: image slots 0 (program CD) and 1 (audio CD; FB_POPN the SPU's data DVD), CHDs served by
// MiSTer_Firebeat (scripts/main_mister).

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];


`ifdef FB_POPN
localparam bit POPN = 1'b1;
`else
localparam bit POPN = 1'b0;
`endif
`ifdef FB_KBM
localparam bit KBM = 1'b1;
`else
localparam bit KBM = 1'b0;
`endif
`ifdef FB_BM3
localparam bit BM3 = 1'b1;          // Beatmania III, with FB_POPN (Firebeat_bm3)
`else
localparam bit BM3 = 1'b0;
`endif

// FB_KBM: the left or right screen (fb_gcu_disp); both stacked is left out of the OSD while one engine
// cannot draw both (HACKS), a new status bit so that a saved Both does not carry over. On HDMI
// ROT270 (firebeat.cpp); CW for a monitor turned the other way
wire [1:0] kbm_screen = {1'b0, status[81]};
wire       kbm_both = KBM && kbm_screen == 2'd2;
wire       direct_video;
// ppp, BM3: HDMI rotation for a monitor on its side, Off by default (the games are ROT0), the same bits
wire       kbm_rot = (KBM ? status[71:70] != 2'd1 : (!POPN || BM3) && status[71:70] != 2'd0) && !direct_video;
wire       kbm_cw = status[71:70] == 2'd2;
// the mod byte's bit 4: the set's disc has the English instruction screens (kbm, kbh; fb_kbm_en)
reg        en_disc = 1'b0;
wire [15:0] rot_late;              // fb_rot16 late: the probes
wire [21:0] perf;                  // fb_board's probe signals (firebeat_sys)
wire [51:0] vprobe;                // the display's and DDR3's probe signals (firebeat_sys)

assign VIDEO_ARX = (!ar) ? (kbm_rot ? 12'd3 : kbm_both ? 12'd2 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (kbm_rot ? (kbm_both ? 12'd2 : 12'd4) : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
`ifdef FB_KBM
	"Firebeat;UART31250,MIDI;",
`elsif FB_BM3
	"Firebeat;UART31250,MIDI;",
`else
	"Firebeat;;",
`endif
	"-;",
	"SC0,CHDBINISOIMG,Program CD;",
`ifdef FB_BM3                       // before FB_POPN, which the bm3 revision also defines
	"SC1,CHDIMG,Hard disk;",
	"S2,IMG,Floppy;",
`elsif FB_POPN
	"SC1,CHDBINISOIMG,Data DVD;",
`else
	"SC1,CHDBINISOIMG,Audio CD;",
`endif
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
`ifdef FB_KBM
	"O[81],Screen,Left,Right;",
	"H1O[71:70],Rotate HDMI,CCW,Off,CW;",
	"H2O[73],Instructions,Japanese,English;",
	"H3O[77:74],MIDI note offset,60,72,84,96,0,12,24,36,48;",
	"H3O[78],MIDI keyboard,1 player,Split;",
	"H3O[80:79],Notes to,MIDI port,Both,arcsnd;",
`endif
`ifdef FB_BM3                       // before FB_POPN, which the bm3 revision also defines
	"H1O[71:70],Rotate HDMI,Off,CCW,CW;",
`elsif FB_POPN
`elsif FB_KBM
`else
	"H1O[71:70],Rotate HDMI,Off,CCW,CW;",
`endif
	"O[72],Flip screen,Off,On;",
`ifdef FB_BM3
	"-;",
	"O[84:83],P1 deck,Auto,Analog,D-pad,Mouse;",
	"O[86:85],P2 deck,Auto,Analog,D-pad,Mouse;",
`endif
	"-;",
	"O[82],Autosave,Off,On;",
`ifdef FB_POPN
`ifndef FB_BM3
	"O[67],Pop'n controller,USB/pad,SNAC;",
`endif
`endif
	"-;",
	"H0P1,Debug;",
	"P1T[64],Dump state / release;",
	"P1O[65],Dump on slave error,Off,On;",
	"-;",
	"R[0],Reset and close OSD;",
`ifdef FB_BM3
	"J1,Key 1,Key 2,Key 3,Key 4,Key 5,Start,Pedal,Coin,Test,Service,Pause,Effect;",
`elsif FB_POPN
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Button 6,Button 7,Button 8,Button 9,Coin,Test,Service,Pause;",
`elsif FB_KBM
	"J1,Start,Coin,Test,Service,Pause;",
`else
	"J1,Sensor 1,Sensor 2,Sensor 3,Sensor 4,Sensor 5,Start,Coin,Test,Service,Pause;",
`endif
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
wire  [31:0] joy, joy1;
wire  [15:0] ana0, ana1;
wire  [24:0] ps2_mouse;
wire  [64:0] hps_rtc;
wire   [7:0] uart_mode;
wire         midi_on = (KBM || BM3) && uart_mode == 8'd3;   // OSD UART mode MIDI

wire        ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
wire [26:0] ioctl_addr;
wire        nvram_save;

// drives 0 and 1 the discs (read only), 2 bm3's floppy (one 512-byte sector a transfer)
wire  [2:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[3];
wire  [5:0] sd_blk_cnt[3];
wire  [2:0] sd_ack;
wire  [2:0] sd_rd;
wire [12:0] sd_buff_addr;
wire [31:0] cd_lba[2];
wire  [5:0] cd_blk_cnt[2];
wire  [1:0] cd_rd;
wire [31:0] fd_lba;
wire        fd_rd, fd_wr;
wire [15:0] fd_buff_din;
assign sd_lba[0] = cd_lba[0];
assign sd_lba[1] = cd_lba[1];
assign sd_lba[2] = fd_lba;
assign sd_blk_cnt[0] = cd_blk_cnt[0];
assign sd_blk_cnt[1] = cd_blk_cnt[1];
assign sd_blk_cnt[2] = 6'd0;
assign sd_rd = {fd_rd, cd_rd};
wire [15:0] sd_buff_dout;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(3), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask({12'd0, !midi_on, !en_disc, direct_video, debug_hidden}),
	.direct_video(direct_video),
	.video_rotated(kbm_rot),
	.joystick_0(joy),
	.joystick_1(joy1),
	.joystick_l_analog_0(ana0),
	.joystick_l_analog_1(ana1),
	.RTC(hps_rtc),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr({fd_wr, 2'b00}),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{16'd0, 16'd0, fd_buff_din}),
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

	.uart_mode(uart_mode),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse)
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

// BM3: scan-out on its own 100.7 MHz clock (fb_vidpll, fb_gcu_disp VCLK); the others on clk_sys
wire clk_vid;
`ifdef FB_BM3
fb_vidpll vid (.refclk(CLK_50M), .clk_vid, .locked());
`else
assign clk_vid = clk_sys;
`endif

wire reset = RESET | status[0] | buttons[1];

///////////////////////   SYSTEM   ///////////////////////////////

wire [7:0]  issp_src;
wire        chk_busy, pat_done;
wire [31:0] chk_sum, chk_lat_sum, brd_pc;
wire [119:0] brd_wd;
wire [22:0] chk_lines;
wire [7:0]  chk_lat_max;
wire [15:0] scan_late, dl_kb;
wire        brd_bad, brd_reset, dump_busy, dump_held;
reg         dump_t_q;
always @(posedge clk_sys) dump_t_q <= status[64];

// ppp: Left and Right from the D-pad (bits 1, 0); the J1 line: the sensor bars 1-5 at 4-8, Start
// 9, Coin 10, Test 11, Service 12, Pause 13. Keyboard: MAME's keys in that layout (arrows; LCtrl
// LAlt Space LShift Z for the bars).
// FB_POPN: the J1 line: buttons 1-9 at 4-12, Coin 13, Test 14, Service 15, Pause 16. Keyboard:
// LCtrl LAlt Space LShift Z X C V B for the buttons.
// FB_KBM: two players, each pad's J1 line Start 4, Coin 5, Test 6, Service 7, Pause 8, Up and Down
// its keyboard's wheel. Keyboard: 1 and 2 start, 5 and 6 coin, F2 test, P pause, the arrows P1's
// wheel, the 24 keys as MAME's (rtl/kbm_keys.sv) on both keyboards. mame_keys puts its keys at
// 11-14, clear of the bits its P2 letters (A S Q W, also keyboard notes) set.
localparam int PAUSE_B = BM3 ? 14 : POPN ? 16 : KBM ? 14 : 13;
wire [31:0] key0, key1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(BM3 ? 5 : POPN ? 9 : KBM ? 0 : 5), .START(BM3 ? 9 : POPN ? 31 : KBM ? 11 : 9), .COIN(BM3 ? 11 : POPN ? 13 : KBM ? 12 : 10),
            .PAUSE(PAUSE_B), .SERVICE(BM3 ? 12 : POPN ? 14 : KBM ? 13 : 11)) u_keys
(
	.clk(clk_sys), .ps2_key, .key0, .key1, .svc_coin(svc_coin)
);
wire [23:0] kbm_k;
kbm_keys u_kbm_keys (.clk(clk_sys), .ps2_key, .keys(kbm_k));
// a MIDI keyboard through MidiLink USB (rtl/kbm_usbmidi.sv)
wire [23:0] midi_k0, midi_k1;
wire  [7:0] midi_w;
wire        midi_w_v;
kbm_usbmidi u_usbmidi (.clk(clk_sys), .enable(midi_on), .rxd(UART_RXD), .offset(status[77:74]), .split(status[78]),
                       .keys0(midi_k0), .keys1(midi_k1), .wheel(midi_w), .wheel_v(midi_w_v));
wire [23:0] kbd[2] = '{kbm_k | midi_k0, kbm_k | midi_k1};
// the XT446's MIDI in (the game's music and key sounds) out to the same MIDI port, for an XG synth,
// with Local Control Off for it (rtl/kbm_midiout.sv); OSD Notes to: the port, both, or the sound
// server only (arcsnd silent for the port alone)
wire        xt_v;
wire  [7:0] xt_byte;
wire        notes_port = KBM && midi_on && status[80:79] != 2'd2;
wire        notes_mute = KBM && midi_on && status[80:79] == 2'd0;
wire        kbm_txd;
kbm_midiout u_midiout (.clk(clk_sys), .enable(notes_port), .tx_v(xt_v), .tx_byte(xt_byte), .txd(kbm_txd));
// BM3: MIDI chan1's transmit line, the cabinet's commands to its ST-224 effects unit (a Zoom
// SampleTrak, MIDI receive only), straight out of the MIDI port; the effects need the real unit
// (MAME has none)
wire        brd_midi_txd;
assign UART_TXD = BM3 ? (midi_on ? brd_midi_txd : 1'b1) : kbm_txd;
wire [7:0]  wheel[2];
// FB_POPN: a PlayStation Pop'n controller on the user port (SNAC), OSD "Pop'n controller". Its
// buttons in the pad's reply (HARDWARE_NOTES "Pop'n controller"): 1 Triangle, 2 Circle, 3 R1,
// 4 Cross, 5 L1, 6 Square, 7 R2, 8 Up, 9 L2; Select is Coin. Pins as PSX_MiSTer's SNAC: USER_OUT
// 1 ATT, 2 CMD, 5 CLK; USER_IN 4 DAT, 3 ACK.
`ifdef FB_POPN
wire snac_on = status[67];
`else
wire snac_on = 1'b0;
`endif
wire        snac_att_n, snac_clk, snac_cmd;
wire [15:0] sb;
psx_pad_snac u_snac (
	.clk(clk_sys), .reset, .enable(snac_on),
	.att_n(snac_att_n), .sclk(snac_clk), .cmd(snac_cmd), .dat(USER_IN[4]), .ack_n(USER_IN[3]),
	.buttons(sb), .id(), .present()
);
assign USER_OUT = snac_on ? {1'b1, snac_clk, 2'b11, snac_cmd, snac_att_n, 1'b1} : '1;
wire [31:0] snac_j = {18'd0, sb[0], sb[8], sb[4], sb[9], sb[15], sb[10], sb[14], sb[11], sb[13], sb[12], 4'd0};
wire [31:0] j = joy | key0 | snac_j;

// ppp's IN0 (firebeat.cpp INPUT_PORTS ppp): active low; 0 Left, 1 Right, 2 Test, 3 Service, 4 Coin,
// 5 Start/OK; bit 6 unused high, bit 7 unused low.
// popn's (INPUT_PORTS popn): IN0 buttons 1-8, active low; IN1 all high; IN2 0 button 9, 2 Coin,
// 4 Test, 6 Service active low, 1 3 5 7 unused low.
// kbm's (INPUT_PORTS kbm): IN0 0 Start 1P, 1 Start 2P, 2 Test, 3 Service, 4 Coin, active low, 5-7
// high; IN2 bit 0 (e-Amusement) active high, low.
wire       k_start1 = joy[4] | key0[11], k_start2 = joy1[4] | key1[11];
wire       k_coin = joy[5] | joy1[5] | key0[12] | key1[12];
wire       k_test = joy[6] | joy1[6] | key0[13], k_svc = joy[7] | joy1[7];
// bm3's (INPUT_PORTS bm3): IN0 0 Test, 1 Service, 2 A, 3 B active low, 4-5 the foot pedals active
// high; IN2 all high; IO1/IO3 P1/P2 keys 1-5 and Start active low, IO2 Coin, IO4 all high. Each
// pad's J1 line: keys 1-5 at 4-8, Start 9, Pedal 10, Coin 11, Test 12, Service 13, Pause 14,
// Effect 15 (rtl/bm3_ctrl.sv); Coin, Test, Service and Pause from either pad. A and B are keyboard
// only (user): MAME's Service 2 and 3 keys, 0 and Minus. Keyboard: mame_keys' P1 and P2 keys,
// 9 Service, X P1's pedal, the dial keys.
wire [31:0] bp1 = joy | key0, bp2 = joy1 | key1;
wire [31:0] bpa = bp1 | bp2;
wire        bm3_pedal1, bm3_kb_b;
wire  [9:0] bm3_tt[2];
wire  [4:0] bm3_dial[7];
bm3_ctrl u_bm3_ctrl (
	.clk(clk_sys), .pad('{bp1, bp2}), .ana('{ana0, ana1}), .mouse(ps2_mouse),
	.src('{status[84:83], status[86:85]}), .ps2_key, .tt(bm3_tt), .dial(bm3_dial), .kb_pedal(bm3_pedal1), .kb_b(bm3_kb_b)
);
wire [7:0] in0 = BM3 ? {2'b00, bp2[10], bp1[10] | bm3_pedal1, ~bm3_kb_b, ~svc_coin[1],
                        ~(bpa[13] | svc_coin[0]), ~bpa[12]}
              : POPN ? ~j[11:4]
              : KBM ? {3'b111, ~k_coin, ~k_svc, ~k_test, ~k_start2, ~k_start1}
              : {1'b0, 1'b1, ~j[9], ~j[10], ~j[12], ~j[11], ~j[0], ~j[1]};
wire [7:0] in2 = BM3 ? 8'hFF : POPN ? {1'b0, ~j[15], 1'b0, ~j[14], 1'b0, ~j[13], 1'b0, ~j[12]} : KBM ? 8'hFE : 8'hFF;
wire j_pause = j[PAUSE_B] | (KBM & (joy[8] | joy1[8])) | (BM3 & joy1[14]);
reg  pause, pause_q;
always @(posedge clk_sys) begin
	pause_q <= j_pause;
	if (j_pause && !pause_q) pause <= ~pause;
	if (reset) pause <= 1'b0;
end
// SENSOR1-4 (firebeat.cpp ppp ports): active high, three sensors a bar, bar n's three bits from
// sensor 3(n-1); bars 6-8 (ppd only) not wired. Not read by POPN's board.
wire [4:0]  bar = j[8:4];
wire [15:0] sensor[4] = '{{8'd0, {2{bar[2]}}, {3{bar[1]}}, {3{bar[0]}}},
                          {12'd0, {3{bar[3]}}, bar[2]},
                          {13'd0, {3{bar[4]}}},
                          16'd0};
// BM3's sensor words (firebeat_bm3_state::sensor_r): IO1-IO4, 4 unread, the turntables' bits 9-8
// and 7-0 (P1, P2), the effect dials 1-7
wire [15:0] bm3_sens[16] = '{16'h003F & ~{10'd0, bp1[9:4]}, {15'd0, ~bpa[11]}, 16'h003F & ~{10'd0, bp2[9:4]}, 16'hFFFF,
                             16'd0, {14'd0, bm3_tt[0][9:8]}, {8'd0, bm3_tt[0][7:0]},
                             {14'd0, bm3_tt[1][9:8]}, {8'd0, bm3_tt[1][7:0]},
                             {11'd0, bm3_dial[0]}, {11'd0, bm3_dial[1]}, {11'd0, bm3_dial[2]}, {11'd0, bm3_dial[3]},
                             {11'd0, bm3_dial[4]}, {11'd0, bm3_dial[5]}, {11'd0, bm3_dial[6]}};
wire        vid_hb, vid_vb, vid_hs, vid_vs, ce_pix;
// FB_KBM: a player's Up and Down push their keyboard's modulation wheel to an end (0xFF, 0x00)
// while held; released, it springs back to 0x80, or for P1 to the MIDI keyboard's mod wheel once that
// has moved. P1's from pad 1 and the arrow keys, P2's from pad 2.
function automatic [7:0] whl(input up, input dn, input mv, input [7:0] mw);
	whl = (up && !dn) ? 8'hFF : (dn && !up) ? 8'h00 : mv ? mw : 8'h80;
endfunction
assign wheel[0] = whl(joy[3] | key0[3], joy[2] | key0[2], midi_w_v, midi_w);
assign wheel[1] = whl(joy1[2], joy1[3], 1'b0, 8'h00);   // player 2's counts the other way: Up is 0x00 (user)
wire signed [15:0] aud_l, aud_r;
// the cabinet register's nibble (firebeat.cpp cabinet_r): the .mra's mod byte, ioctl index 1; 8 the
// Japanese ppp sets, 9 the overseas ppd (init_ppp_overseas), 0 popn4 (init_popn_jp)
reg  [3:0] cabinet = 4'd8;
always @(posedge clk_sys) if (ioctl_download && ioctl_wr && ioctl_index == 16'd1 && ioctl_addr == 27'd0) {en_disc, cabinet} <= ioctl_dout[4:0];
wire kbm_en = KBM && en_disc && status[73];
wire nv_wr;
// signed, muted while paused (the board's YMZ280B and CD audio run on)
assign AUDIO_S = 1;
assign AUDIO_L = pause ? 16'd0 : aud_l;
assign AUDIO_R = pause ? 16'd0 : aud_r;
wire [7:0]  vid_r, vid_g, vid_b;
wire        rot_fb_en;
wire [4:0]  rot_fb_format;
wire [11:0] rot_fb_width, rot_fb_height;
wire [31:0] rot_fb_base;
wire [13:0] rot_fb_stride;
`ifdef MISTER_FB
wire        rot_fb_vbl = FB_VBL, rot_fb_ll = FB_LL;
assign FB_EN = rot_fb_en;
assign FB_FORMAT = rot_fb_format;
assign FB_WIDTH = rot_fb_width;
assign FB_HEIGHT = rot_fb_height;
assign FB_BASE = rot_fb_base;
assign FB_STRIDE = rot_fb_stride;
assign FB_FORCE_BLANK = 0;
`else
wire        rot_fb_vbl = 1'b0, rot_fb_ll = 1'b0;
`endif

assign DDRAM_CLK = clk_sys;

firebeat_sys #(.POPN(POPN), .KBM(KBM), .BM3(BM3)) sys (
	.clk(clk_sys), .clk_mem, .clk_vid, .pll_locked, .reset, .hps_reset(RESET),
	.hold(issp_src[6]), .pause, .hps_rtc,
	.dump_start(status[64] && !dump_t_q), .dump_on_err(status[65]), .dump_busy, .dump_held,
	.ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout,
	.ioctl_upload, .ioctl_rd, .ioctl_din, .ioctl_wait,
	.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
	.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE,
	.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
	.DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
	.img_mounted(img_mounted[1:0]), .img_size, .sd_lba(cd_lba), .sd_blk_cnt(cd_blk_cnt), .sd_rd(cd_rd), .sd_ack(sd_ack[1:0]),
	.sd_buff_wr, .sd_buff_dout,
	.fd_mounted(img_mounted[2]), .fd_readonly(img_readonly), .fd_lba, .fd_rd, .fd_wr, .fd_ack(sd_ack[2]),
	.sd_buff_addr(sd_buff_addr[8:0]), .fd_buff_din,
	.in0, .in1(8'hFF), .in2, .in3(8'hFF), .sensor, .bm3_sens, .cabinet_info(cabinet), .kbm_en, .kbd, .wheel, .midi_txd(brd_midi_txd), .midi_tx_v(xt_v), .midi_tx_byte(xt_byte), .midi_mute(BM3 ? midi_on : notes_mute),
	.ce_pix, .vid_r, .vid_g, .vid_b, .vid_hs, .vid_vs, .vid_hb, .vid_vb,
	.chk_start(issp_src[1]), .chk_sel(issp_src[2]), .pat_start(issp_src[3]), .pat_variant(issp_src[4]),
	.test_pic(issp_src[7]), .screen(kbm_screen), .flip(status[72]), .rot_en(kbm_rot), .rot_cw(kbm_cw), .rot_late,
	.FB_EN(rot_fb_en), .FB_FORMAT(rot_fb_format), .FB_WIDTH(rot_fb_width), .FB_HEIGHT(rot_fb_height),
	.FB_BASE(rot_fb_base), .FB_STRIDE(rot_fb_stride), .FB_VBL(rot_fb_vbl), .FB_LL(rot_fb_ll),
	.chk_busy, .chk_sum, .chk_lines, .chk_lat_sum, .chk_lat_max,
	.scan_late, .pat_done, .dl_kb, .brd_pc, .brd_wd, .brd_bad, .brd_reset, .aud_l, .aud_r, .nv_wr, .perf, .vprobe
);

// the NVRAM file's save: Main uploads it on the next OSD open after this rises (menu.cpp
// MENU_SAVE_CHECK); dirty from the board's first flash or RTC write after the last upload, held back
// while Autosave is off (the default, since a failing run saves its state too; bit 82, not 66, so
// that a saved Off does not turn into On). The stp revision's probe F can also request one.
reg  nv_dirty = 1'b0, nv_up_q = 1'b0;
always @(posedge clk_sys) begin
	nv_up_q <= ioctl_upload;
	if (ioctl_upload && !nv_up_q) nv_dirty <= 1'b0;
	else if (nv_wr) nv_dirty <= 1'b1;
end
assign nvram_save = (nv_dirty && status[82]) | issp_src[5];

///////////////////////   VIDEO   ////////////////////////////////

assign CLK_VIDEO = clk_vid;
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
reg         vs_q;
`ifdef FB_KBM
`define FB_PROBES_KX
`elsif FB_BM3
`define FB_PROBES_KX                // bm3: one GCU, its engine's draw time against the CPU's held writes
`endif
`ifndef FB_PROBES_KX
// probe F (scripts/read_issp.tcl fields_F): bring-up. frame_50m is the last frame's length in
// CLK_50M clocks, which checks the PLL and the timing together (58.4877 Hz: 854,881).
// Sources: [0] clear the frame counter, [1] start a read-back pass (probe M), [2] its range
// (0 BIOS, 1 flash), [3] rewrite the test picture, [4] inverted, [5] request the NVRAM save,
// [6] hold the board in reset (needed for a read-back pass), [7] show the test picture instead
// of the GCU's display. cabinet, idx1_wr (index-1 writes) and dl_idx (the last download's index)
// check the .mra's mod byte.
reg  [15:0] frames;
always @(posedge clk_sys) begin
	vs_q <= vid_vs;
	if (vid_vs && !vs_q && frames != 16'hFFFF) frames <= frames + 1'd1;
	if (issp_src[0]) frames <= 16'd0;
end
reg  [7:0]  idx1_wr = 8'd0;
reg  [3:0]  dl_idx = 4'd0;
always @(posedge clk_sys) begin
	if (ioctl_download) dl_idx <= ioctl_index[3:0];
	if (ioctl_download && ioctl_wr && ioctl_index == 16'd1 && idx1_wr != 8'hFF) idx1_wr <= idx1_wr + 1'd1;
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
	.probe({dl_idx, idx1_wr, cabinet, pll_locked, pat_done, chk_busy, ioctl_download, scan_late, dl_kb,
	        frame_50m, frames}),
	.source(issp_src)
);
// probe M: the last read-back pass, and the board: its CPU's PC, a model's unsupported mode
issp_probe #(.INSTANCE_ID("M"), .PROBE_W(129), .SOURCE_W(1)) u_probe_m (
	.clk(clk_sys),
	.probe({brd_reset, brd_bad, brd_pc, chk_lat_max, chk_lat_sum, chk_lines, chk_sum}),
	.source()
);
`else
// probes K and X (fields_K, fields_X): kbm's and bm3's draw time and sound, per frame of the core's
// video (bm3: GCU 1's fields read 0, except l_h1, the clocks a frame register write waited for the
// engine). K, the last frame: the shared engine's clocks running for
// GCU 0 / 1, its clocks waiting on DDR3, the clocks each GCU's queue was full, the clocks a CPU port
// write to each was held, the deepest each queue got; busy_vbl, frames that began with the engine
// running, and hold_vbl, frames that began with a CPU port write held. X, since source 0 (or
// power-on): the most engine clocks, held clocks and full clocks in a frame, the frames with a held
// write, the YMZ280B's lost ticks, longest voice pass and longest sample read, fb_rot16's dropped
// slices, the frames counted, fb_gcu_disp's late lines since reset; bm3: the most command words
// (CPU or DMA) reaching a GCU port in a frame, the frames with more than 8 (the two list calls),
// and the command words from the DMA (its list rows are VRAM words). F and M are left out for area; K's source [0] clears X.
wire        k_src;
assign issp_src = {7'd0, k_src};
reg  [1:0]  vs_s;                                           // bm3's vid_vs is on clk_vid
always @(posedge clk_sys) begin vs_s <= {vs_s[0], vid_vs}; vs_q <= vs_s[1]; end
reg  [20:0] k_b0, k_b1, k_mw, k_f0, k_f1, k_h0, k_h1;      // running
reg  [5:0]  k_d0, k_d1;
reg  [20:0] l_b0, l_b1, l_mw, l_f0, l_f1, l_h0, l_h1;      // the last frame
reg  [5:0]  l_d0, l_d1;
reg  [15:0] busy_vbl, hold_vbl, x_frames, frames_held, y_lost;
reg  [20:0] x_busy, x_hold;
reg  [21:0] x_full;                                         // both queues can be full at once
reg  [11:0] y_pass, y_pass_max;
reg  [9:0]  y_fetch, y_fetch_max;
reg  [15:0] c_cmdw, x_cmdw_max, x_cmdx;                     // bm3: command words a frame, the most, frames with more than 8
reg  [19:0] x_dmacmd;                                       // bm3: command words from the DMA
wire        k_frame = vs_s[1] && !vs_q;
always @(posedge clk_sys) begin
	if (perf[0] && !perf[1]) k_b0 <= k_b0 + 1'd1;
	if (perf[0] &&  perf[1]) k_b1 <= k_b1 + 1'd1;
	if (perf[2]) k_mw <= k_mw + 1'd1;
	if (perf[3]) k_f0 <= k_f0 + 1'd1;
	if (perf[4]) k_f1 <= k_f1 + 1'd1;
	if (perf[5]) k_h0 <= k_h0 + 1'd1;
	if (perf[6]) k_h1 <= k_h1 + 1'd1;
	if (perf[15:10] > k_d0) k_d0 <= perf[15:10];
	if (perf[21:16] > k_d1) k_d1 <= perf[21:16];
	if (perf[16] && c_cmdw != 16'hFFFF) c_cmdw <= c_cmdw + 1'd1;
	if (perf[17] && x_dmacmd != 20'hFFFFF) x_dmacmd <= x_dmacmd + 1'd1;
	if (k_frame) begin
		c_cmdw <= 16'd0;
		if (c_cmdw > x_cmdw_max) x_cmdw_max <= c_cmdw;
		if (c_cmdw > 16'd8 && x_cmdx != 16'hFFFF) x_cmdx <= x_cmdx + 1'd1;
		{l_b0, l_b1, l_mw, l_f0, l_f1, l_h0, l_h1, l_d0, l_d1} <= {k_b0, k_b1, k_mw, k_f0, k_f1, k_h0, k_h1, k_d0, k_d1};
		{k_b0, k_b1, k_mw, k_f0, k_f1, k_h0, k_h1, k_d0, k_d1} <= '0;
		if (perf[0] && busy_vbl != 16'hFFFF) busy_vbl <= busy_vbl + 1'd1;
		if (perf[5] && hold_vbl != 16'hFFFF) hold_vbl <= hold_vbl + 1'd1;
		if (x_frames != 16'hFFFF) x_frames <= x_frames + 1'd1;
		if (k_b0 + k_b1 > x_busy) x_busy <= k_b0 + k_b1;
		if (k_h0 + k_h1 > x_hold) x_hold <= k_h0 + k_h1;
		if ({1'b0, k_f0} + {1'b0, k_f1} > x_full) x_full <= {1'b0, k_f0} + {1'b0, k_f1};
		if ((k_h0 != 21'd0 || k_h1 != 21'd0) && frames_held != 16'hFFFF) frames_held <= frames_held + 1'd1;
	end
	if (perf[7] && y_lost != 16'hFFFF) y_lost <= y_lost + 1'd1;
	if (perf[8]) y_pass <= y_pass + 1'd1;
	else begin if (y_pass > y_pass_max) y_pass_max <= y_pass; y_pass <= 12'd0; end
	if (perf[9]) y_fetch <= y_fetch + 1'd1;
	else begin if (y_fetch > y_fetch_max) y_fetch_max <= y_fetch; y_fetch <= 10'd0; end
	if (issp_src[0]) begin
		{busy_vbl, hold_vbl, x_frames, frames_held, y_lost, x_busy, x_hold, x_full, y_pass_max, y_fetch_max} <= '0;
		{x_cmdw_max, x_cmdx, x_dmacmd} <= '0;
	end
end
issp_probe #(.INSTANCE_ID("K"), .PROBE_W(191), .SOURCE_W(1)) u_probe_k (
	.clk(clk_sys),
	.probe({hold_vbl, busy_vbl, l_d1, l_d0, l_h1, l_h0, l_f1, l_f0, l_mw, l_b1, l_b0}),
	.source(k_src)
);
issp_probe #(.INSTANCE_ID("X"), .PROBE_W(218), .SOURCE_W(1)) u_probe_x (
	.clk(clk_sys),
	.probe({x_dmacmd, x_cmdx, x_cmdw_max, scan_late, x_frames, rot_late, y_fetch_max, y_pass_max, y_lost, frames_held, x_full, x_hold, x_busy}),
	.source()
);
issp_probe #(.INSTANCE_ID("W"), .PROBE_W(120), .SOURCE_W(1)) u_probe_w (
	.clk(clk_sys),
	.probe(brd_wd),
	.source()
);
`ifdef FB_BM3
// probes V and E (fields_V, fields_E): the picture's bottom third flashing black. Per frame of the
// output: black pixels in lines 0-159, 160-319 and 320-479 (bm3's 480 lines), counted on clk_vid;
// on clk_sys the display's late lines, the first late row and the longest run of them, its longest
// line build and longest wait for the DDR3 port, the longest DDRAM_BUSY run and DDRAM_BUSY's clocks,
// the rows at which the engine first started and last stopped and whether it ran at the frame's
// start, the GCU's beats into the frame on screen with the row being built at the first and the
// row it wrote, and context 0's base. V: the last frame, then since K's source 0: frames with a late
// line, the most late lines, the longest build, wait and DDRAM_BUSY run, frames with a beat into
// the frame on screen. E: the last frame whose bottom third had 16,384 black pixels more than the
// frame before (the event), the events, and x_frames at it.
reg  [16:0] bk_c0, bk_c1, bk_c2, bk0, bk1, bk2;
reg  [9:0]  bk_y;
reg         bk_de, bk_vs;
wire        bk_on = !(vid_hb || vid_vb);
always @(posedge clk_vid) begin
	if (ce_pix) begin
		bk_de <= bk_on;
		if (bk_on && !bk_de) bk_y <= bk_y + 1'd1;
		if (bk_on && bk_y != 10'd0 && vid_r == 8'd0 && vid_g == 8'd0 && vid_b == 8'd0) begin
			if (bk_y <= 10'd160) bk_c0 <= bk_c0 + 1'd1;
			else if (bk_y <= 10'd320) bk_c1 <= bk_c1 + 1'd1;
			else bk_c2 <= bk_c2 + 1'd1;
		end
	end
	bk_vs <= vid_vs;
	if (vid_vs && !bk_vs) begin
		{bk0, bk1, bk2} <= {bk_c0, bk_c1, bk_c2};
		{bk_c0, bk_c1, bk_c2} <= '0;
		bk_y <= 10'd0;
	end
end

wire [11:0] v_row   = vprobe[11:0];
wire        v_lst   = vprobe[12];
wire        v_late  = vprobe[13];
wire        v_build = vprobe[14];
wire        v_rwait = vprobe[15];
wire [23:0] v_base0 = vprobe[39:16];
wire        v_busy  = vprobe[40];
wire        v_dhit  = vprobe[41];
wire [9:0]  v_drow  = vprobe[51:42];
reg  [11:0] v_cur;                                          // the row whose build last began
reg  [9:0]  c_late, c_run, c_runmax;
reg  [11:0] c_lrow;
reg  [11:0] c_bld, c_bldmax, c_rw, c_rwmax;
reg  [15:0] c_bz, c_bzmax;
reg  [20:0] c_bzn;
reg  [11:0] c_eon, c_eoff;
reg         c_evbl, e_q;
reg  [15:0] c_dwr;
reg  [11:0] c_dwrow;
reg  [9:0]  c_dwdst;
// the last frame: {bk0, bk1, bk2, late, lrow, runmax, bldmax, rwmax, bzmax, bzn, eon, eoff, evbl, dwr, dwrow, dwdst, base0}
reg  [230:0] lf, ev;
reg  [15:0] ev_n, ev_fr, m_latefr, m_dwrfr, m_bz;
reg  [9:0]  m_late;
reg  [11:0] m_bld, m_rw;
reg  [3:0]  kf_d;
reg  [16:0] pv_bk2;
always @(posedge clk_sys) begin
	if (v_lst) begin
		v_cur <= v_row;
		if (v_late) begin
			if (c_late != 10'h3FF) c_late <= c_late + 1'd1;
			if (c_lrow == 12'hFFF) c_lrow <= v_row;
			if (c_run != 10'h3FF) c_run <= c_run + 1'd1;
			if (c_run + 1'd1 > c_runmax) c_runmax <= c_run + 1'd1;
		end else c_run <= 10'd0;
	end
	if (v_build) begin if (c_bld != 12'hFFF) c_bld <= c_bld + 1'd1; end
	else begin if (c_bld > c_bldmax) c_bldmax <= c_bld; c_bld <= 12'd0; end
	if (v_rwait) begin if (c_rw != 12'hFFF) c_rw <= c_rw + 1'd1; end
	else begin if (c_rw > c_rwmax) c_rwmax <= c_rw; c_rw <= 12'd0; end
	if (v_busy) begin
		if (c_bz != 16'hFFFF) c_bz <= c_bz + 1'd1;
		if (c_bzn != 21'h1FFFFF) c_bzn <= c_bzn + 1'd1;
	end else begin if (c_bz > c_bzmax) c_bzmax <= c_bz; c_bz <= 16'd0; end
	e_q <= perf[0];
	if (perf[0] && !e_q && c_eon == 12'hFFF) c_eon <= v_cur;
	if (!perf[0] && e_q) c_eoff <= v_cur;
	if (v_dhit) begin
		if (c_dwr != 16'hFFFF) c_dwr <= c_dwr + 1'd1;
		if (c_dwr == 16'd0) begin c_dwrow <= v_cur; c_dwdst <= v_drow; end
	end
	kf_d <= {kf_d[2:0], k_frame};
	if (k_frame) begin
		lf[230:51] <= {c_late, c_lrow, c_runmax, c_bldmax, c_rwmax, c_bzmax, c_bzn, c_eon, c_eoff, c_evbl,
		               c_dwr, c_dwrow, c_dwdst, v_base0};
		if (c_late != 10'd0 && m_latefr != 16'hFFFF) m_latefr <= m_latefr + 1'd1;
		if (c_late > m_late) m_late <= c_late;
		if (c_bldmax > m_bld) m_bld <= c_bldmax;
		if (c_rwmax > m_rw) m_rw <= c_rwmax;
		if (c_bzmax > m_bz) m_bz <= c_bzmax;
		if (c_dwr != 16'd0 && m_dwrfr != 16'hFFFF) m_dwrfr <= m_dwrfr + 1'd1;
		{c_late, c_run, c_runmax, c_bldmax, c_rwmax, c_bzmax, c_bzn, c_dwr} <= '0;
		c_lrow <= 12'hFFF; c_eon <= 12'hFFF; c_eoff <= 12'hFFF; c_dwrow <= 12'hFFF; c_dwdst <= 10'h3FF;
		c_evbl <= perf[0];
	end
	// the black counts, latched on clk_vid at the same vsync, have held still for a few clocks by now
	if (kf_d[3]) begin
		lf[50:0] <= {bk0, bk1, bk2};
		if (bk2 > pv_bk2 + 17'd16384) begin
			ev <= {lf[230:51], bk0, bk1, bk2};
			if (ev_n != 16'hFFFF) ev_n <= ev_n + 1'd1;
			ev_fr <= x_frames;
		end
		pv_bk2 <= bk2;
	end
	if (issp_src[0]) {m_latefr, m_late, m_bld, m_rw, m_bz, m_dwrfr, ev_n} <= '0;
end
issp_probe #(.INSTANCE_ID("V"), .PROBE_W(313), .SOURCE_W(1)) u_probe_v (
	.clk(clk_sys),
	.probe({m_dwrfr, m_bz, m_rw, m_bld, m_late, m_latefr, lf}),
	.source()
);
issp_probe #(.INSTANCE_ID("E"), .PROBE_W(263), .SOURCE_W(1)) u_probe_e (
	.clk(clk_sys),
	.probe({ev_fr, ev_n, ev}),
	.source()
);
`endif
`endif
`else
assign issp_src = 8'd0;
`endif

endmodule
