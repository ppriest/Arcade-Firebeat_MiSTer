// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboardmania's 24 keys from a PS/2 keyboard, MAME's codes (konami/midikbd.cpp INPUT_PORTS):
// Q W E R T Y U I O A S D F G H J K L Z X C V B N, C1 up to B2. MAME gives both MIDI keyboards
// the same keys.

module kbm_keys (
	input             clk,
	input      [10:0] ps2_key,          // hps_io: [10] toggles per event, [9] pressed, [8] E0, [7:0] set-2 code
	output reg [23:0] keys = 24'd0
);

reg tog = 1'b0;
always @(posedge clk) begin
	tog <= ps2_key[10];
	if (ps2_key[10] != tog && !ps2_key[8])
		case (ps2_key[7:0])
			8'h15: keys[0]  <= ps2_key[9]; // Q  C1
			8'h1D: keys[1]  <= ps2_key[9]; // W  C1#
			8'h24: keys[2]  <= ps2_key[9]; // E  D1
			8'h2D: keys[3]  <= ps2_key[9]; // R  D1#
			8'h2C: keys[4]  <= ps2_key[9]; // T  E1
			8'h35: keys[5]  <= ps2_key[9]; // Y  F1
			8'h3C: keys[6]  <= ps2_key[9]; // U  F1#
			8'h43: keys[7]  <= ps2_key[9]; // I  G1
			8'h44: keys[8]  <= ps2_key[9]; // O  G1#
			8'h1C: keys[9]  <= ps2_key[9]; // A  A1
			8'h1B: keys[10] <= ps2_key[9]; // S  A1#
			8'h23: keys[11] <= ps2_key[9]; // D  B1
			8'h2B: keys[12] <= ps2_key[9]; // F  C2
			8'h34: keys[13] <= ps2_key[9]; // G  C2#
			8'h33: keys[14] <= ps2_key[9]; // H  D2
			8'h3B: keys[15] <= ps2_key[9]; // J  D2#
			8'h42: keys[16] <= ps2_key[9]; // K  E2
			8'h4B: keys[17] <= ps2_key[9]; // L  F2
			8'h1A: keys[18] <= ps2_key[9]; // Z  F2#
			8'h22: keys[19] <= ps2_key[9]; // X  G2
			8'h21: keys[20] <= ps2_key[9]; // C  G2#
			8'h2A: keys[21] <= ps2_key[9]; // V  A2
			8'h32: keys[22] <= ps2_key[9]; // B  A2#
			8'h31: keys[23] <= ps2_key[9]; // N  B2
			default: ;
		endcase
end

endmodule
