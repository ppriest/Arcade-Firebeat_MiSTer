// SPDX-License-Identifier: GPL-3.0-or-later
//
// kbm_midiout: game bytes in (a running-status sequence, then game_tx.txt, chan1's bytes from MAME's
// kbm play capture debug/kbm-play/midi.txt), the UART decoded, the bytes written to out.txt for
// check.py. REPEAT is short so that Local Off goes in often, between and around every kind of
// message; the output is also disabled and enabled once.
//
//     scripts/run_verilator.sh midiout_tb && python sim/midiout_tb/check.py
`timescale 1ns/1ps
module tb_midiout;
	logic clk = 0;
	always #7.5 clk = ~clk;

	logic       enable = 0, tx_v = 0, txd;
	logic [7:0] tx_byte = 0;

	kbm_midiout #(.REPEAT(300_000)) dut (.clk, .enable, .tx_v, .tx_byte, .txd);

	// the receiver: 15 ns x 2133.33 a bit
	localparam real BIT = 32000.0;
	int fo;
	initial begin
		logic [7:0] b;
		fo = $fopen("sim/midiout_tb/out.txt", "w");
		forever begin
			@(negedge txd);
			#(BIT * 1.5);
			for (int i = 0; i < 8; i++) begin b[i] = txd; #(BIT); end
			if (!txd) $display("FAIL: framing");
			$fdisplay(fo, "%02X", b);
		end
	end

	task automatic put(input logic [7:0] b, input int gap);
		@(posedge clk); tx_v <= 1; tx_byte <= b;
		@(posedge clk); tx_v <= 0;
		repeat (gap) @(posedge clk);
	endtask

	initial begin
		int fd, n, k;
		logic [7:0] b;
		logic [7:0] seq [] = '{8'h90, 8'h3C, 8'h40, 8'h3E, 8'h40, 8'h40, 8'h40, 8'hB0, 8'h07, 8'h64,
		                       8'h0A, 8'h40, 8'hC0, 8'h05, 8'h06, 8'hF0, 8'h43, 8'h10, 8'h4C, 8'h00,
		                       8'h00, 8'h7E, 8'h00, 8'hF7, 8'h91, 8'h3C, 8'hF8, 8'h00, 8'h3E, 8'h00,
		                       8'hE0, 8'h00, 8'h40, 8'h10, 8'h40, 8'hD0, 8'h20, 8'h21};
		#(1000);
		enable = 1;
		for (int r = 0; r < 4; r++)
			foreach (seq[i]) put(seq[i], 30000 + 13000 * ((i + r) % 5));
		fd = $fopen("sim/midiout_tb/game_tx.txt", "r");
		k = 0;
		while (!$feof(fd)) begin
			n = $fscanf(fd, "%h", b);
			if (n != 1) break;
			put(b, 22000 + 9000 * (k % 4));
			k++;
			if (k == 1000) begin #(3_000_000); enable = 0; #(5_000_000); enable = 1; end
		end
		#(20_000_000);
		$fclose(fo);
		$display("done: %0d game bytes", k);
		$finish;
	end
endmodule
