// SPDX-License-Identifier: GPL-3.0-or-later
//
// The XT446's MIDI (chan1's transmitted bytes) out of the MiSTer's UART at 31250 baud, with Local
// Control Off (B0 7A 00) put in when the output is enabled and every REPEAT clocks after, so that a
// keyboard playing the notes does not sound its own keys as well (switched on later, it gets it at
// the next repeat). The insert goes only between whole messages, never inside SysEx; after it the
// game's status byte is sent again before a message that leaned on running status.

module kbm_midiout #(
	parameter int REPEAT = 133_333_333          // 2 s at 66.667 MHz
) (
	input            clk,                       // 66.667 MHz
	input            enable,
	input            tx_v,                      // a byte the game sent (fb_board midi_tx_*)
	input      [7:0] tx_byte,
	output reg       txd = 1'b1
);

// data bytes a channel status takes
function automatic [1:0] len(input [7:0] s);
	len = (s[7:5] == 3'b110) ? 2'd1 : 2'd2;
endfunction

reg  [7:0]  q [16];
reg  [3:0]  wp = 4'd0, rp = 4'd0;
wire [3:0]  used = wp - rp;

reg  [7:0]  rs = 8'd0;                      // the game's running status; 0 none
reg  [1:0]  need = 2'd0;                    // data bytes left in the current message
reg         in_sx = 1'b0, broke = 1'b1, pend = 1'b0, en_q = 1'b0;
reg  [27:0] rep = 28'd0;

always @(posedge clk) begin
	reg [3:0] w;
	w = wp;
	en_q <= enable;
	if (rep == 28'(REPEAT - 1)) begin rep <= 28'd0; pend <= 1'b1; end
	else rep <= rep + 28'd1;
	if (enable && !en_q) begin pend <= 1'b1; rep <= 28'd0; end

	if (tx_v) begin
		if (tx_byte >= 8'hF8) begin q[w] <= tx_byte; w = w + 4'd1; end
		else if (tx_byte == 8'hF0) begin in_sx <= 1'b1; rs <= 8'd0; q[w] <= tx_byte; w = w + 4'd1; end
		else if (tx_byte == 8'hF7) begin in_sx <= 1'b0; q[w] <= tx_byte; w = w + 4'd1; end
		else if (tx_byte >= 8'hF1) begin
			in_sx <= 1'b0; rs <= 8'd0;
			need <= (tx_byte == 8'hF2) ? 2'd2 : (tx_byte == 8'hF1 || tx_byte == 8'hF3) ? 2'd1 : 2'd0;
			q[w] <= tx_byte; w = w + 4'd1;
		end else if (tx_byte[7]) begin
			in_sx <= 1'b0; rs <= tx_byte; need <= len(tx_byte); broke <= 1'b0;
			q[w] <= tx_byte; w = w + 4'd1;
		end else if (in_sx || need != 2'd0 || rs == 8'd0) begin
			if (need != 2'd0) need <= need - 2'd1;
			q[w] <= tx_byte; w = w + 4'd1;
		end else begin
			// a new message on running status
			need <= len(rs) - 2'd1;
			if (broke) begin q[w] <= rs; w = w + 4'd1; broke <= 1'b0; end
			q[w] <= tx_byte; w = w + 4'd1;
		end
	end else if (pend && enable && need == 2'd0 && !in_sx && used < 4'd12) begin
		q[w] <= 8'hB0; q[w + 4'd1] <= 8'h7A; q[w + 4'd2] <= 8'h00;
		w = w + 4'd3;
		pend <= 1'b0;
		broke <= 1'b1;
	end
	wp <= w;
	if (!enable) begin wp <= rp; broke <= 1'b1; end
end

// the transmitter: 3 in 6,400 clocks a bit
reg  [12:0] acc = 13'd0;
reg  [3:0]  tbit = 4'd0;                    // bits left; 0 idle
reg  [9:0]  tsr = 10'h3FF;
always @(posedge clk) begin
	if (tbit == 4'd0) begin
		acc <= 13'd0;
		txd <= 1'b1;
		if (enable && wp != rp) begin tsr <= {1'b1, q[rp], 1'b0}; tbit <= 4'd10; rp <= rp + 4'd1; end
	end else if (acc >= 13'd6397) begin
		acc <= acc - 13'd6397;
		txd <= tsr[0];
		tsr <= {1'b1, tsr[9:1]};
		tbit <= tbit - 4'd1;
	end else acc <= acc + 13'd3;
end

endmodule
