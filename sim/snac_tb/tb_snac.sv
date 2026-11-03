// SPDX-License-Identifier: GPL-3.0-or-later
//
// psx_pad_snac against a pad model: a digital pad (Pop'n reply, ID 41), an analog one (ID 73, three
// halfwords), a reply without 5A, and no pad. The model sets DAT on the clock's falling edge, reads
// CMD on its rising edge and pulses ACK 4.5 us after every byte but the last, at 66.667 MHz.
//
//     scripts/run_verilator.sh snac_tb
`timescale 1ns/1ps
module tb_snac;
	logic clk = 0, reset = 1;
	always #7.5 clk = ~clk;

	logic att_n, sclk, cmd, dat, ack_n;
	logic [15:0] buttons;
	logic [7:0]  id;
	logic        present;

	psx_pad_snac #(.PERIOD(12)) dut (
		.clk, .reset, .enable(1'b1), .att_n, .sclk, .cmd, .dat, .ack_n, .buttons, .id, .present
	);

	// the pad
	logic [7:0] reply [0:8];
	int         nbytes;                 // 0: no pad
	logic [7:0] cmd_got [0:8];
	logic       sclk_q = 1, att_q = 1;
	int         byten, bitn, ackt = -1, bytes_seen;
	logic [7:0] shin;
	always_ff @(posedge clk) begin
		sclk_q <= sclk; att_q <= att_n;
		if (ackt >= 0) ackt <= ackt + 1;
		if (ackt == 300) ack_n <= 1'b0;
		if (ackt == 450) begin ack_n <= 1'b1; ackt <= -1; end
		if (att_n && !att_q) bytes_seen <= byten;
		if (att_n) begin dat <= 1'b1; byten <= 0; bitn <= 0; end
		else if (nbytes != 0 && byten < nbytes) begin
			if (sclk_q && !sclk) dat <= reply[byten][bitn];
			if (!sclk_q && sclk) begin
				shin <= {cmd, shin[7:1]};
				if (bitn == 7) begin
					cmd_got[byten] <= {cmd, shin[7:1]};
					if (byten < nbytes - 1) ackt <= 0;
					byten <= byten + 1; bitn <= 0;
				end else bitn <= bitn + 1;
			end
		end
	end

	int fails = 0;
	task automatic expect_poll(string name, logic want_p, logic [15:0] want_b, logic [7:0] want_id);
		@(negedge att_n); @(posedge att_n); @(posedge att_n);   // the second full poll
		repeat (4) @(posedge clk);
		if (present !== want_p || buttons !== want_b || id !== want_id) begin
			$display("FAIL %s: present %b buttons %04h id %02h, want %b %04h %02h", name, present, buttons, id,
			         want_p, want_b, want_id);
			fails++;
		end else $display("ok   %s: present %b buttons %04h id %02h", name, present, buttons, id);
	endtask

	initial begin
		ack_n = 1'b1;
		// Pop'n: Left Down Right held, button 1 (Triangle) and 8 (Up) pressed
		reply[0] = 8'hFF; reply[1] = 8'h41; reply[2] = 8'h5A; reply[3] = 8'h0F; reply[4] = 8'hEF;
		nbytes = 5;
		repeat (10) @(posedge clk);
		reset = 0;
		expect_poll("digital", 1'b1, 16'h10F0, 8'h41);
		if (cmd_got[0] !== 8'h01 || cmd_got[1] !== 8'h42 || cmd_got[2] !== 8'h00 || cmd_got[4] !== 8'h00) begin
			$display("FAIL commands %02h %02h %02h %02h %02h", cmd_got[0], cmd_got[1], cmd_got[2], cmd_got[3], cmd_got[4]);
			fails++;
		end

		reply[1] = 8'h73; reply[3] = 8'hFE; reply[4] = 8'h7F;     // Select, Square
		reply[5] = 8'h80; reply[6] = 8'h80; reply[7] = 8'h80; reply[8] = 8'h80;
		nbytes = 9;
		expect_poll("analog", 1'b1, 16'h8001, 8'h73);
		if (bytes_seen !== 9) begin $display("FAIL analog: %0d bytes clocked, want 9", bytes_seen); fails++; end

		reply[1] = 8'h41; reply[2] = 8'h00; nbytes = 5;
		expect_poll("no 5A", 1'b0, 16'h0000, 8'h41);

		nbytes = 0;
		expect_poll("no pad", 1'b0, 16'h0000, 8'hFF);

		if (fails) $display("FAILED"); else $display("PASSED");
		$finish;
	end
endmodule
