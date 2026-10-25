// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PC16552D dual UART at 0x7DC00000 (firebeat.cpp:773-775, 794: "duart_com", the network UART,
// its interrupt lines unconnected), as registers only: two NS16550 channels (channel 0 at offsets
// 0-7, channel 1 at 8-15) read back as MAME's ins8250_r returns them. Nothing is sent or received,
// so the transmitter is always empty (LSR 0x60) and the only interrupt is THR-empty: pending after
// an IER write enabling it, a THR write or a transmit FIFO reset, cleared by reading IIR while it is
// the one shown (ins8250.cpp write/read, ns16550 set_fcr). MSR reads 0.

module fb_pc16552 (
    input  logic       clk,
    input  logic       reset,
    input  logic       req,             // a byte access, one clock
    input  logic       we,
    input  logic [3:0] addr,
    input  logic [7:0] wdata,
    output logic [7:0] rdata            // the clock after req
);

logic [7:0] ier [2], lcr [2], mcr [2], scr [2], dll [2], dlm [2];
logic [1:0] fifo, thre;                 // FIFOs on (IIR 0xC0), THR-empty pending

always_ff @(posedge clk) begin
    logic c, show;
    c = addr[3];
    show = ier[c][1] && thre[c];
    if (req) begin
        if (we) case (addr[2:0])
            3'd0: if (lcr[c][7]) dll[c] <= wdata; else thre[c] <= 1'b1;
            3'd1: if (lcr[c][7]) dlm[c] <= wdata;
                  else begin ier[c] <= wdata; if (wdata[1]) thre[c] <= 1'b1; end
            3'd2: begin fifo[c] <= wdata[0]; if (wdata[0] && (wdata[2] || !fifo[c])) thre[c] <= 1'b1; end
            3'd3: lcr[c] <= wdata;
            3'd4: mcr[c] <= wdata;
            3'd7: scr[c] <= wdata;
            default: ;
        endcase
        else case (addr[2:0])
            3'd0: rdata <= lcr[c][7] ? dll[c] : 8'h00;
            3'd1: rdata <= lcr[c][7] ? dlm[c] : {4'h0, ier[c][3:0]};
            3'd2: begin
                rdata <= {fifo[c] ? 2'b11 : 2'b00, 4'h0, show ? 2'b10 : 2'b01};
                if (show) thre[c] <= 1'b0;
            end
            3'd3: rdata <= lcr[c];
            3'd4: rdata <= mcr[c];
            3'd5: rdata <= 8'h60;
            3'd6: rdata <= 8'h00;
            default: rdata <= scr[c];
        endcase
    end
    if (reset) begin
        fifo <= 2'b00; thre <= 2'b00;
        for (int k = 0; k < 2; k++) begin
            ier[k] <= 8'h00; lcr[k] <= 8'h00; mcr[k] <= 8'h00; scr[k] <= 8'h00;
            dll[k] <= 8'h00; dlm[k] <= 8'h00;
        end
    end
end

endmodule
