// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 2's YMZ280B (0x7D000400-0x7D000401): MAME's register interface (devices/sound/ymz280b.cpp
// read, write, write_to_register) without the voices (Phase 4). Offset 0 written selects a
// register, offset 1 written writes it; registers are kept for Phase 4. Offset 1 read is the
// status register, which only the voices set, so it reads 0 here; offset 0 read is the external
// memory readback: with FF bit 6 (ext_mem_enable) it returns the latch, which is then refilled from
// the next address (the address advancing); 0xFF otherwise. Register 0x86 completes the readback
// address (0x84, 0x85, 0x86 high to low) and fills the latch; 0x87 writes nothing (MAME's
// ymz280b_map has no write: firebeat.cpp:804-808).
//
// The external memory is the two sound flash chips (fb_flash port y). An access arriving while the
// latch is being refilled waits for it.

module fb_ymz_shell (
    input  logic        clk,
    input  logic        reset,

    input  logic        req,            // a byte access, held until ack
    input  logic        we,
    input  logic        a0,
    input  logic [7:0]  wdata,
    output logic        ack,
    output logic [7:0]  rdata,

    output logic        y_req,
    output logic [21:0] y_addr,
    input  logic        y_ack,
    input  logic [7:0]  y_rdata,

    output logic [7:0]  reg_q,          // register reg_a's value (Phase 4)
    input  logic [7:0]  reg_a
);

logic [7:0]  regs [256];
logic [7:0]  cur, hi, mid, latch;
logic [23:0] ea;
logic        ext_en;

always_ff @(posedge clk) reg_q <= regs[reg_a];

always_ff @(posedge clk) begin
    ack <= 1'b0;
    if (y_req && y_ack) begin y_req <= 1'b0; latch <= y_rdata; end
    if (req && !ack && !y_req) begin
        ack <= 1'b1;
        if (we) begin
            if (!a0) cur <= wdata;
            else begin
                regs[cur] <= wdata;
                case (cur)
                8'h84: hi <= wdata;
                8'h85: mid <= wdata;
                8'h86: begin
                    ea <= {hi, mid, wdata};
                    if (ext_en) begin y_req <= 1'b1; y_addr <= {hi[5:0], mid, wdata}; end
                end
                8'h87: if (ext_en) ea <= ea + 24'd1;
                8'hFF: ext_en <= wdata[6];
                default: ;
                endcase
            end
        end else if (!a0) begin
            if (!ext_en) rdata <= 8'hFF;
            else begin
                rdata <= latch;
                y_req <= 1'b1; y_addr <= ea[21:0]; ea <= ea + 24'd1;
            end
        end else rdata <= 8'h00;
    end
    if (reset) begin y_req <= 1'b0; ext_en <= 1'b0; ea <= '0; cur <= 8'h00; end
end

endmodule
