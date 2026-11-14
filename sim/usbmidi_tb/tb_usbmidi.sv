// SPDX-License-Identifier: GPL-3.0-or-later
//
// kbm_usbmidi against sim/usbmidi_tb/vectors.txt (make_vectors.py): bytes on rxd at 31250 baud,
// 8N1, at 66.667 MHz, and the keys checked after each message.
//
//     python sim/usbmidi_tb/make_vectors.py
//     scripts/run_verilator.sh usbmidi_tb
`timescale 1ns/1ps
module tb_usbmidi;
	logic clk = 0;
	always #7.5 clk = ~clk;

	logic        enable = 0, rxd = 1, split = 0;
	logic [3:0]  offset = 0;
	logic [23:0] keys0, keys1;

	kbm_usbmidi dut (.clk, .enable, .rxd, .offset, .split, .keys0, .keys1);

	localparam real BIT = 32000.0;     // ns

	task automatic send(input logic [7:0] b);
		rxd = 0; #(BIT);
		for (int i = 0; i < 8; i++) begin rxd = b[i]; #(BIT); end
		rxd = 1; #(BIT);
	endtask

	initial begin
		int fd, n, errs, checks, a, c;
		string op;
		fd = $fopen("sim/usbmidi_tb/vectors.txt", "r");
		if (fd == 0) begin $display("FAIL: no vectors.txt"); $finish; end
		errs = 0; checks = 0;
		#(1000);
		while (!$feof(fd)) begin
			n = $fscanf(fd, "%s", op);
			if (n != 1) break;
			case (op)
			"E": begin n = $fscanf(fd, "%d", a); enable = a[0]; #(100); end
			"O": begin n = $fscanf(fd, "%h %d", a, c); offset = a[3:0]; split = c[0]; #(100); end
			"B": begin n = $fscanf(fd, "%h", a); send(a[7:0]); end
			"W": begin n = $fscanf(fd, "%d", a); #(real'(a) * 1.0e6); end
			"C": begin
				n = $fscanf(fd, "%h %h", a, c);
				checks++;
				if (keys0 !== a[23:0] || keys1 !== c[23:0]) begin
					errs++;
					if (errs <= 10) $display("check %0d: keys %06h %06h, expected %06h %06h", checks, keys0, keys1, a[23:0], c[23:0]);
				end
			end
			default: begin $display("FAIL: bad command %s", op); $finish; end
			endcase
		end
		$display("%s: %0d checks, %0d errors", errs ? "FAIL" : "PASS", checks, errs);
		$finish;
	end
endmodule
