// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboardmania's keys from a MIDI keyboard on the MiSTer's UART: OSD UART mode MIDI, MidiLink
// USB, bridging a USB MIDI keyboard to UART_RXD at 31250 baud. Note On/Off on any channel (Note On
// at velocity 0 is an off) set a 128-note map; the keys are a 24-note window of it from note 0, 12,
// ... 96 (60 is C4, the game's own first note, midikbd.cpp's 3C). One player: the window on both
// keyboards, as kbm_keys does. Split: the window on P1's, the 24 notes above it on P2's.
// Running status is kept; realtime bytes (clock F8, active sense FE) pass through without
// breaking it; system common and SysEx cancel it. All notes clear on CC 120 or 123, when off, or
// when active sense has been seen and the line then goes quiet for 300 ms.
// The modulation wheel (CC 1, any channel) sets P1's wheel, 0-127 as 0x00-0xFF, and marks it valid
// until disabled.

module kbm_usbmidi (
	input             clk,                  // 66.667 MHz
	input             enable,               // UART mode MIDI
	input             rxd,
	input       [3:0] offset,               // the window's first note: 60, 72, 84, 96, 0, 12, 24, 36, 48
	input             split,
	output reg [23:0] keys0 = 24'd0,        // P1 (left), 1 = down
	output reg [23:0] keys1 = 24'd0,
	output reg  [7:0] wheel = 8'd0,         // P1's
	output reg        wheel_v = 1'b0
);

// 31250 baud from 66.667 MHz: 3 in 6,400, exact
reg  [1:0]  rq = 2'b11;
reg  [12:0] acc = 13'd0;
reg  [1:0]  rs_state = 2'd0;            // 0 idle, 1 start, 2 data, 3 stop
reg  [2:0]  bitn = 3'd0;
reg  [7:0]  sh = 8'd0;
reg         rx_v = 1'b0;
reg  [7:0]  rx_b = 8'd0;

always @(posedge clk) begin
	rq <= {rq[0], rxd};
	rx_v <= 1'b0;
	case (rs_state)
	2'd0: if (!rq[1]) begin acc <= 13'd0; rs_state <= 2'd1; end
	2'd1: if (acc >= 13'd3197) begin
	          acc <= acc - 13'd3197;
	          bitn <= 3'd0;
	          rs_state <= rq[1] ? 2'd0 : 2'd2;      // a glitch, not a start bit
	      end else acc <= acc + 13'd3;
	2'd2: if (acc >= 13'd6397) begin
	          acc <= acc - 13'd6397;
	          sh <= {rq[1], sh[7:1]};
	          bitn <= bitn + 3'd1;
	          if (bitn == 3'd7) rs_state <= 2'd3;
	      end else acc <= acc + 13'd3;
	2'd3: if (acc >= 13'd6397) begin
	          rx_v <= rq[1];                        // a framing error drops the byte
	          rx_b <= sh;
	          rs_state <= 2'd0;
	      end else acc <= acc + 13'd3;
	endcase
end

// the parser
reg  [127:0] on = 128'd0;
reg  [7:0]   rstat = 8'd0;              // running status; 0 none
reg          second = 1'b0;             // the next data byte is the message's second
reg  [6:0]   d1 = 7'd0;
reg          sensed = 1'b0;
reg  [24:0]  quiet = 25'd0;             // clocks since the last byte

always @(posedge clk) begin
	if (rx_v) quiet <= 25'd0;
	else if (quiet != 25'd20_000_000) quiet <= quiet + 25'd1;

	if (rx_v) begin
		if (rx_b >= 8'hF8) begin
			if (rx_b == 8'hFE) sensed <= 1'b1;
		end else if (rx_b >= 8'hF0) rstat <= 8'd0;
		else if (rx_b[7]) begin rstat <= rx_b; second <= 1'b0; end
		else if (rstat != 8'd0) begin
			if (rstat[7:5] == 3'b110) second <= 1'b0;      // Cn, Dn: one data byte
			else if (!second) begin d1 <= rx_b[6:0]; second <= 1'b1; end
			else begin
				second <= 1'b0;
				if (rstat[7:5] == 3'b100) on[d1] <= rstat[4] && rx_b != 8'd0;
				if (rstat[7:4] == 4'hB && d1 == 7'd1) begin wheel <= {rx_b[6:0], rx_b[6]}; wheel_v <= 1'b1; end
				if (rstat[7:4] == 4'hB && (d1 == 7'd120 || d1 == 7'd123)) on <= 128'd0;
			end
		end
	end

	if (sensed && quiet == 25'd20_000_000) begin on <= 128'd0; sensed <= 1'b0; end
	if (!enable) begin
		on <= 128'd0; rstat <= 8'd0; sensed <= 1'b0;
		wheel_v <= 1'b0;
	end
end

wire [151:0] onx = {24'd0, on};
always @(posedge clk) begin
	reg [23:0] w0, w1;
	case (offset)
	4'd1:    begin w0 = onx[72 +: 24]; w1 = onx[96 +: 24];  end
	4'd2:    begin w0 = onx[84 +: 24]; w1 = onx[108 +: 24]; end
	4'd3:    begin w0 = onx[96 +: 24]; w1 = onx[120 +: 24]; end
	4'd4:    begin w0 = onx[0 +: 24];  w1 = onx[24 +: 24];  end
	4'd5:    begin w0 = onx[12 +: 24]; w1 = onx[36 +: 24];  end
	4'd6:    begin w0 = onx[24 +: 24]; w1 = onx[48 +: 24];  end
	4'd7:    begin w0 = onx[36 +: 24]; w1 = onx[60 +: 24];  end
	4'd8:    begin w0 = onx[48 +: 24]; w1 = onx[72 +: 24];  end
	default: begin w0 = onx[60 +: 24]; w1 = onx[84 +: 24];  end
	endcase
	keys0 <= w0;
	keys1 <= split ? w1 : w0;
end

endmodule
