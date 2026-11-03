// SPDX-License-Identifier: GPL-3.0-or-later
//
// A PlayStation controller on the user port through a SNAC adapter, polled as the console does:
// ATT low, then 01 42 00 00 00 ... at ~250 kHz, LSB first, CMD set on the clock's falling edge and
// DAT read on its rising edge; the pad pulses ACK low after every byte but the last. The reply is
// FF, its ID (low nibble: halfwords to follow), 5A, then the button halfword, active low:
//   byte 4: Select L3 R3 Start Up Right Down Left   (bits 0-7)
//   byte 5: L2 R2 L1 R1 Triangle Circle Cross Square
// (PSX_MiSTer rtl/joypad_pad.vhd). The whole reply is clocked through so analog pads end cleanly;
// only the first halfword is kept. Pins and the ACK filter follow PSX_MiSTer's PSX.sv (PROVENANCE).
//
// Timing parameters are clocks of clk; the defaults are for 66.667 MHz.

module psx_pad_snac #(
	parameter int HALF    = 133,      // half a bit: 250 kHz
	parameter int ATT_SU  = 1333,     // ATT low to the first clock: 20 us
	parameter int ACK_TO  = 6667,     // no ACK within 100 us: no pad, or the reply ended
	parameter int GAP     = 667,      // ACK seen to the next byte: 10 us
	parameter int PERIOD  = 17        // a poll every 2^PERIOD clocks: 2 ms
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        enable,

	output logic        att_n,
	output logic        sclk,
	output logic        cmd,
	input  logic        dat,
	input  logic        ack_n,

	output logic [15:0] buttons,      // byte 5 : byte 4, active high; 0 with no pad
	output logic [7:0]  id,           // the last reply's ID byte
	output logic        present
);

	logic [1:0] dat_s, ack_s;
	logic [3:0] ack_f;
	always_ff @(posedge clk) begin
		dat_s <= {dat_s[0], dat};
		ack_s <= {ack_s[0], ack_n};
		ack_f <= {ack_f[2:0], ack_s[1]};
	end
	wire ack_low = ack_f == 4'd0;

	typedef enum logic [2:0] {IDLE, SETUP, LO, HI, ACKW, WAIT} st_t;
	st_t        st;
	logic [PERIOD-1:0] idle;
	logic [12:0] t;
	localparam logic [12:0] T_HALF = 13'(HALF), T_SU = 13'(ATT_SU), T_TO = 13'(ACK_TO), T_GAP = 13'(GAP);
	logic [2:0]  bitn;
	logic [5:0]  byten, last;
	logic [7:0]  tx, rx, rid, b4;
	logic        ok;

	wire [7:0] tx_next = (byten == 6'd0) ? 8'h42 : 8'h00;    // byten: the byte just finished

	always_ff @(posedge clk) begin
		if (reset || !enable) begin
			st <= IDLE; idle <= '0; att_n <= 1'b1; sclk <= 1'b1; cmd <= 1'b1;
			buttons <= 16'd0; present <= 1'b0; id <= 8'hFF;
		end else case (st)
			IDLE: begin
				idle <= idle + 1'd1;
				if (&idle) begin
					att_n <= 1'b0; t <= '0; st <= SETUP;
					tx <= 8'h01; byten <= '0; bitn <= '0; last <= 6'd4; ok <= 1'b1;
				end
			end
			SETUP: begin
				t <= t + 1'd1;
				if (t == T_SU) begin t <= '0; sclk <= 1'b0; cmd <= tx[0]; st <= LO; end
			end
			LO: begin
				t <= t + 1'd1;
				if (t == T_HALF) begin t <= '0; sclk <= 1'b1; rx <= {dat_s[1], rx[7:1]}; st <= HI; end
			end
			HI: begin
				t <= t + 1'd1;
				if (t == T_HALF) begin
					t <= '0;
					bitn <= bitn + 1'd1;
					if (bitn != 3'd7) begin sclk <= 1'b0; cmd <= tx[bitn + 1'd1]; st <= LO; end
					else begin
						cmd <= 1'b1;
						case (byten)
							6'd1: begin rid <= rx; last <= {(rx[3:0] == 4'd0), rx[3:0], 1'b0} + 6'd2; end
							6'd2: ok <= rx == 8'h5A;
							6'd3: b4 <= rx;
							6'd4: begin
								buttons <= ok ? ~{rx, b4} : 16'd0;
								id <= rid;
								present <= ok;
							end
							default: ;
						endcase
						if (byten == last) begin att_n <= 1'b1; st <= IDLE; end
						else begin tx <= tx_next; st <= ACKW; end
					end
				end
			end
			ACKW: begin
				t <= t + 1'd1;
				if (ack_low) begin t <= '0; st <= WAIT; end
				else if (t == T_TO) begin
					att_n <= 1'b1; st <= IDLE;
					if (byten < 6'd4) begin present <= 1'b0; buttons <= 16'd0; id <= 8'hFF; end
				end
			end
			WAIT: begin
				t <= t + 1'd1;
				if (t == T_GAP) begin t <= '0; byten <= byten + 1'd1; sclk <= 1'b0; cmd <= tx[0]; st <= LO; end
			end
			default: st <= IDLE;
		endcase
	end

endmodule
