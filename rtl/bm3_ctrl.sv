// SPDX-License-Identifier: GPL-3.0-or-later
//
// Beatmania III's turntables and effect dials (firebeat.cpp INPUT_PORTS bm3: TURNTABLE_P1/P2 a
// 10-bit trackball X count, EFFECT1-7 5-bit dials, both wrapping), and the keys mame_keys leaves out.
//
// A deck's count from its OSD source (ROADMAP Phase 10 step 7, as the light-gun aim sources):
//   0 Auto    the stick past a dead zone moves the platter absolutely, up to AMAX counts from
//             rest; at full deflection it turns it at KEYSTEP a frame; the d-pad turns it
//   1 Analog  the stick absolutely over its whole range; the d-pad turns it
//   2 D-pad   the d-pad, and the stick past half way, turn it
//   3 Mouse   the mouse's X counts, one to one; the d-pad turns it
// While the pad's Effect button is held its deck stands still and its d-pad turns the program
// dials instead: Up/Down setting A's (dial 3), Right/Left setting B's (dial 7), a step a press.
// Keyboard: X player 1's pedal (MAME's P1 Foot), Minus the B button (MAME's Service 3); two keys a dial, down and up: 1 T Y, 2 U I,
// 3 H J, 4 K L, 5 N M, 6 , ., 7 ; '.

module bm3_ctrl #(
	parameter int TICK    = 1_111_111,  // clk cycles a frame: 66.667 MHz / 60
	parameter int KEYSTEP = 15          // counts a frame for a held direction (MAME's PORT_KEYDELTA)
) (
	input               clk,
	input        [31:0] pad [2],        // per player: hps_io layout, right 0 left 1 down 2 up 3, Effect 15
	input        [15:0] ana [2],        // hps_io joystick_l_analog: X [7:0], -127..127
	input        [24:0] mouse,          // hps_io ps2_mouse: [24] toggles a packet, [4] X sign, [15:8] X
	input         [1:0] src [2],        // OSD deck source per player
	input        [10:0] ps2_key,
	output logic  [9:0] tt [2] = '{10'd0, 10'd0},
	output logic  [4:0] dial [7] = '{5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0},
	output logic        kb_pedal = 1'b0,
	output logic        kb_b = 1'b0
);

localparam int AMAX = 56;   // Auto: the absolute part's reach, counts
localparam logic signed [7:0]  AMAX_P = AMAX;
localparam logic signed [7:0]  AMAX_N = -AMAX;
localparam logic signed [10:0] STEP_P = KEYSTEP;
localparam logic signed [10:0] STEP_N = -KEYSTEP;

// the frame tick
logic [20:0] tcnt = '0;
logic        tick;
always_ff @(posedge clk) begin
	if (tcnt == TICK - 1)
		tcnt <= '0;
	else
		tcnt <= tcnt + 1'd1;
end
assign tick = tcnt == TICK - 1;

// the mouse's X counts since the last tick
logic        mtog = 1'b0;
logic [11:0] macc = '0;
wire  [11:0] mdx = {{3{mouse[4]}}, mouse[4], mouse[15:8]};
always_ff @(posedge clk) begin
	mtog <= mouse[24];
	if (tick)
		macc <= (mouse[24] != mtog) ? mdx : 12'd0;
	else if (mouse[24] != mtog)
		macc <= macc + mdx;
end

// keyboard: pedal and dial keys; a press is one step
logic       ktog = 1'b0;
logic [6:0] kdn, kup;
always_ff @(posedge clk) begin
	ktog <= ps2_key[10];
	kdn  <= '0;
	kup  <= '0;
	if (ps2_key[10] != ktog && !ps2_key[8]) begin
		case (ps2_key[7:0])
			8'h22: kb_pedal <= ps2_key[9];       // X
			8'h4E: kb_b <= ps2_key[9];           // -
			8'h2C: kdn[0] <= ps2_key[9];         // T
			8'h35: kup[0] <= ps2_key[9];         // Y
			8'h3C: kdn[1] <= ps2_key[9];         // U
			8'h43: kup[1] <= ps2_key[9];         // I
			8'h33: kdn[2] <= ps2_key[9];         // H
			8'h3B: kup[2] <= ps2_key[9];         // J
			8'h42: kdn[3] <= ps2_key[9];         // K
			8'h4B: kup[3] <= ps2_key[9];         // L
			8'h31: kdn[4] <= ps2_key[9];         // N
			8'h3A: kup[4] <= ps2_key[9];         // M
			8'h41: kdn[5] <= ps2_key[9];         // ,
			8'h49: kup[5] <= ps2_key[9];         // .
			8'h4C: kdn[6] <= ps2_key[9];         // ;
			8'h52: kup[6] <= ps2_key[9];         // '
			default: ;
		endcase
	end
end

// the pads' Effect shift: d-pad presses while Effect is held
logic [3:0] pad_q [2] = '{4'd0, 4'd0};
logic [3:0] press [2];
always_ff @(posedge clk) begin
	pad_q[0] <= pad[0][3:0];
	pad_q[1] <= pad[1][3:0];
end
always_comb begin
	for (int p = 0; p < 2; p++) begin
		press[p] = pad[p][15] ? (pad[p][3:0] & ~pad_q[p]) : 4'd0;
	end
end
wire a_up = press[0][3] | press[1][3];
wire a_dn = press[0][2] | press[1][2];
wire b_up = press[0][0] | press[1][0];
wire b_dn = press[0][1] | press[1][1];

always_ff @(posedge clk) begin
	for (int d = 0; d < 7; d++) begin
		logic up, dn;
		up = kup[d] | (d == 2 && a_up) | (d == 6 && b_up);
		dn = kdn[d] | (d == 2 && a_dn) | (d == 6 && b_dn);
		if (up && !dn)
			dial[d] <= dial[d] + 1'd1;
		else if (dn && !up)
			dial[d] <= dial[d] - 1'd1;
	end
end

// the decks
logic signed [7:0] a_prev [2] = '{8'sd0, 8'sd0};
always_ff @(posedge clk) begin
	if (tick) begin
		for (int p = 0; p < 2; p++) begin
			logic signed [7:0]  ax, tgt;
			logic signed [10:0] step;
			logic               r, l, full, half, dz;
			ax   = $signed(ana[p][7:0]);
			full = ax >= 8'sd112 || ax <= -8'sd112;
			half = ax >= 8'sd64 || ax <= -8'sd64;
			dz   = ax < 8'sd8 && ax > -8'sd8;
			r    = pad[p][0] && !pad[p][1];
			l    = pad[p][1] && !pad[p][0];
			tgt  = 8'sd0;
			case (src[p])
				2'd0: begin
					if (full) begin
						tgt = ax[7] ? AMAX_N : AMAX_P;
						r   = r | !ax[7];
						l   = l | ax[7];
					end
					else if (!dz) begin
						tgt = ax >>> 1;
					end
				end
				2'd1: begin
					if (!dz) begin
						tgt = ax >>> 1;
					end
				end
				2'd2: begin
					if (half) begin
						r = r | !ax[7];
						l = l | ax[7];
					end
				end
				default: ;
			endcase
			step = 11'sd0;
			if (r && !l) begin
				step = STEP_P;
			end
			else if (l && !r) begin
				step = STEP_N;
			end
			if (src[p] == 2'd3) begin
				step = step + $signed(macc[10:0]);
			end
			step = step + {{3{tgt[7]}}, tgt} - {{3{a_prev[p][7]}}, a_prev[p]};
			a_prev[p] <= tgt;
			if (!pad[p][15]) begin
				tt[p] <= tt[p] + step[9:0];
			end
		end
	end
end

endmodule
