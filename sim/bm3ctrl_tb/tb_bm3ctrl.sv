// SPDX-License-Identifier: GPL-3.0-or-later
//
// bm3_ctrl: each deck source, the Effect shift, the dial keys, the pedal key and B's key. A frame is
// TICK = 16 clocks here; KEYSTEP 15 as MAME's PORT_KEYDELTA.
//
//     scripts/run_verilator.sh bm3ctrl_tb
`timescale 1ns/1ps
module tb_bm3ctrl;
	logic clk = 0;
	always #7.5 clk = ~clk;

	logic [31:0] pad [2] = '{32'd0, 32'd0};
	logic [15:0] ana [2] = '{16'd0, 16'd0};
	logic [24:0] mouse = '0;
	logic  [1:0] src [2] = '{2'd0, 2'd0};
	logic [10:0] ps2_key = '0;
	logic  [9:0] tt [2];
	logic  [4:0] dial [7];
	logic        kb_pedal, kb_b;

	bm3_ctrl #(.TICK(16)) dut (.clk, .pad, .ana, .mouse, .src, .ps2_key, .tt, .dial, .kb_pedal, .kb_b);

	int errs = 0;

	task automatic frames(input int n);
		repeat (16 * n) @(posedge clk);
	endtask

	task automatic check_tt(input int p, input int want, input string what);
		if (tt[p] !== 10'(want)) begin
			$display("FAIL %s: deck %0d %0d, want %0d", what, p + 1, tt[p], want & 10'h3FF);
			errs++;
		end
		else begin
			$display("ok   %s: deck %0d %0d", what, p + 1, tt[p]);
		end
	endtask

	task automatic check_dial(input int d, input int want, input string what);
		if (dial[d] !== 5'(want)) begin
			$display("FAIL %s: dial %0d %0d, want %0d", what, d + 1, dial[d], want & 5'h1F);
			errs++;
		end
		else begin
			$display("ok   %s: dial %0d %0d", what, d + 1, dial[d]);
		end
	endtask

	task automatic key(input logic [7:0] code, input logic down);
		@(posedge clk);
		ps2_key <= {~ps2_key[10], down, 1'b0, code};
		@(posedge clk);
		@(posedge clk);
	endtask

	task automatic packet(input int dx);
		@(posedge clk);
		mouse <= {~mouse[24], 8'd0, 8'(dx), 3'd0, dx < 0, 4'd0};
		@(posedge clk);
	endtask

	initial begin
		frames(2);
		check_tt(0, 0, "at rest");

		// d-pad right held 3 frames, then left 1 (Auto)
		pad[0][0] = 1;
		frames(3);
		pad[0][0] = 0;
		frames(1);
		check_tt(0, 45, "d-pad right 3 frames");
		pad[0][1] = 1;
		frames(1);
		pad[0][1] = 0;
		frames(1);
		check_tt(0, 30, "d-pad left 1 frame");

		// Auto, partial: absolute, half the stick
		ana[0] = 16'(8'sd40);
		frames(3);
		check_tt(0, 50, "Auto stick +40");
		ana[0] = 16'(-8'sd20);
		frames(2);
		check_tt(0, 20, "Auto stick -20");
		ana[0] = 16'(8'sd4);
		frames(2);
		check_tt(0, 30, "Auto stick in the dead zone");

		// Auto, full: the reach, then KEYSTEP a frame
		ana[0] = 16'(8'sd127);
		frames(1);
		check_tt(0, 30 + 56 + 15, "Auto stick full, frame 1");
		frames(2);
		check_tt(0, 30 + 56 + 45, "Auto stick full, frame 3");
		ana[0] = 16'd0;
		frames(1);
		check_tt(0, 30 + 45, "Auto stick released");

		// Analog: absolute over the whole range
		src[0] = 2'd1;
		ana[0] = 16'(8'sd127);
		frames(3);
		check_tt(0, 75 + 63, "Analog stick full");
		ana[0] = 16'd0;
		frames(1);
		check_tt(0, 75, "Analog stick released");

		// D-pad: the stick past half way turns it
		src[0] = 2'd2;
		ana[0] = 16'(-8'sd80);
		frames(2);
		ana[0] = 16'(8'sd40);
		frames(2);
		check_tt(0, 75 - 30, "D-pad source, stick -80 2 frames, +40 ignored");
		ana[0] = 16'd0;

		// Mouse: counts one to one, the stick ignored
		src[0] = 2'd3;
		packet(10);
		packet(-3);
		ana[0] = 16'(8'sd100);
		frames(2);
		check_tt(0, 45 + 7, "mouse +10 -3");
		ana[0] = 16'd0;
		packet(-60);
		frames(1);
		check_tt(0, 52 - 60, "mouse -60 (wraps)");

		// deck 2 is independent: Auto stick, deck 1 unmoved by it
		ana[1] = 16'(8'sd50);
		frames(2);
		check_tt(1, 25, "deck 2 Auto stick +50");
		check_tt(0, 52 - 60, "deck 1 unmoved");
		ana[1] = 16'd0;
		frames(1);

		// Effect held: deck still; Up/Down dial 3, Right/Left dial 7, a step a press
		src[0] = 2'd0;
		pad[0][15] = 1;
		pad[0][3] = 1;
		frames(3);
		pad[0][3] = 0;
		frames(1);
		pad[0][3] = 1;
		frames(1);
		pad[0][3] = 0;
		pad[0][0] = 1;
		frames(1);
		pad[0][0] = 0;
		pad[0][1] = 1;
		frames(1);
		pad[0][1] = 0;
		pad[0][1] = 1;
		frames(1);
		pad[0][1] = 0;
		frames(1);
		check_dial(2, 2, "Effect + Up twice");
		check_dial(6, 0, "Effect + Right, Left");
		check_tt(0, 52 - 60, "deck still while Effect held");
		pad[1][15] = 1;
		pad[1][2] = 1;
		frames(1);
		pad[1][2] = 0;
		pad[1][15] = 0;
		pad[0][15] = 0;
		frames(1);
		check_dial(2, 1, "P2 Effect + Down");
		pad[0][1] = 1;
		frames(1);
		pad[0][1] = 0;
		frames(1);
		check_dial(6, 0, "Left without Effect");
		check_tt(0, 52 - 60 - 15, "Left without Effect turns the deck");

		// keyboard: T dial 1 down, Y up twice; ' dial 7 up; a release is no step; X the pedal
		key(8'h2C, 1);
		key(8'h2C, 0);
		check_dial(0, 31, "T");
		key(8'h35, 1);
		key(8'h35, 0);
		key(8'h35, 1);
		key(8'h35, 0);
		check_dial(0, 1, "Y twice");
		key(8'h52, 1);
		key(8'h52, 0);
		check_dial(6, 1, "'");
		key(8'h22, 1);
		if (!kb_pedal) begin
			$display("FAIL X: pedal not down");
			errs++;
		end
		key(8'h22, 0);
		if (kb_pedal) begin
			$display("FAIL X: pedal not up");
			errs++;
		end
		key(8'h4E, 1);
		if (!kb_b) begin
			$display("FAIL Minus: B not down");
			errs++;
		end
		key(8'h4E, 0);
		if (kb_b) begin
			$display("FAIL Minus: B not up");
			errs++;
		end

		$display("%s (%0d errors)", errs ? "FAIL" : "PASS", errs);
		$finish;
	end
endmodule
