// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PPC403's serial port (SPU, internal map 0x40000000-0x4000000F) as MAME runs it
// (ppccom.cpp:3146-3372), with the DS1991 iButton behind its DS2480B line driver on it
// (firebeat.cpp:820-985, ibutton_w and security_w).
//
// Registers (byte offsets): 0 line status (reset 0x06; a write clears the bits it sets of 0xF8),
// 2 handshake status, 4/5 baud divisor high/low, 6 control, 7 receive command, 8 transmit command,
// 9 the buffer (read: the received byte, clearing status bit 7; write: the byte to send, clearing
// bit 2). Other offsets read 0xFF.
//
// MAME's timer, kept: every character period (clock x (divisor + 1) x 16 x bits per character,
// bits = 7 + control[3] + 1 + control[0]; clock 66 MHz, or 3.6864 MHz with IOCR bit 1) while the
// receiver or transmitter is enabled, restarted when that, the divisor, control bits 0/3 or IOCR
// bit 1 change. Each period the transmitter moves a full buffer out (status bit 2 set, bit 1
// cleared), or else sets bit 1; the byte goes to the DS1991, whose reply (if any) joins the receive
// queue; and the receiver takes the queue's next byte into the buffer (status bit 7), or flags an
// overrun (bit 5) if the buffer is still full. Interrupts as MAME's update_irq_states, and only
// when MAME calls it: after each period, and on a write to the line status or a command register.
// Reading the buffer leaves the receive interrupt standing until then; the BIOS's dispatcher,
// clearing EXISR after the handler, sees it again and runs the handler a second time, which
// clears the line status (ppccom.cpp:3150-3175, 3289, 3304-3335).
//
// The DS1991: DS2480B reset 0xC1 answers 0xCD; 0xE1/0xE3 (data/command mode) answer nothing; 0x66
// (read subkey) and 0xCC (skip ROM) are echoed; read subkey then echoes its two command bytes and
// returns the 64 bytes of subkey (first command byte bits 7:6) from the dongle image (identifier,
// password, data at subkey x 64), zeros for subkey 3. Any other command sets `bad` (MAME stops with
// a fatal error).

module fb_spu (
    input  logic        clk,
    input  logic        reset,
    input  logic        tick66,         // the 66 MHz system clock's enable (the timebase's)
    input  logic        iocr_b1,        // IOCR bit 1: the serial clock

    input  logic        req,            // a byte access, one clock
    input  logic        we,
    input  logic [3:0]  addr,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,          // the clock after req

    output logic        irq_rx,
    output logic        irq_tx,
    output logic        bad,

    // the dongle image (firebeat.cpp set_ibutton): 3 x (8 identifier, 8 password, 48 data)
    input  logic        ld_we,
    input  logic [7:0]  ld_addr,
    input  logic [7:0]  ld_data
);

localparam logic [3:0] R_LS = 4'd0, R_BRDH = 4'd4, R_BRDL = 4'd5, R_CTL = 4'd6, R_RXC = 4'd7,
                       R_TXC = 4'd8, R_BUF = 4'd9;

logic [7:0] regs [9];
logic [7:0] txbuf, rxbuf;

// ---------------------------------------------------------------- the character timer
// the serial clock: 3.6864 MHz from 66.667 MHz, 864/15625 (exact)
logic [13:0] sacc;
logic        tick_ser;
always_ff @(posedge clk) begin
    tick_ser <= 1'b0;
    if (sacc >= 14'd14761) begin sacc <= sacc - 14'd14761; tick_ser <= 1'b1; end   // + 864 - 15625
    else sacc <= sacc + 14'd864;
    if (reset) sacc <= '0;
end
wire        tick = iocr_b1 ? tick_ser : tick66;
wire [11:0] div  = {regs[R_BRDH][3:0], regs[R_BRDL]};
wire [3:0]  bpc  = 4'd8 + {3'd0, regs[R_CTL][3]} + {3'd0, regs[R_CTL][0]};
wire        enabled = regs[R_RXC][7] || regs[R_TXC][7];
logic [11:0] dcnt;
logic [7:0]  bcnt;                      // bit-clock ticks: 16 x bpc a character
logic        restart, period;
always_ff @(posedge clk) begin
    period <= 1'b0;
    if (enabled && tick) begin
        if (dcnt == div) begin
            dcnt <= 12'd0;
            if (bcnt == {bpc, 4'd0} - 8'd1) begin bcnt <= 8'd0; period <= 1'b1; end
            else bcnt <= bcnt + 8'd1;
        end else dcnt <= dcnt + 12'd1;
    end
    if (restart || reset) begin dcnt <= 12'd0; bcnt <= 8'd0; end
end

// ---------------------------------------------------------------- the DS1991
logic [7:0] dongle [256];
always_ff @(posedge clk) if (ld_we) dongle[ld_addr] <= ld_data;

logic        ib_sub;                    // reading a subkey
logic [6:0]  ib_ptr;
logic [1:0]  ib_key;
logic [7:0]  dg_q;
// the subkey byte the next transmitted byte returns: its address changes only on a transmitted
// byte, a character period before the next, so dg_q is ready then
wire  [5:0]  sk_i = ib_ptr[5:0] - 6'd2;
always_ff @(posedge clk) dg_q <= dongle[{ib_key, sk_i}];

// the receive queue
logic [7:0]  rq [16];
logic [3:0]  rq_in, rq_out;
wire         rq_empty = rq_in == rq_out;

// a transmitted byte, answered the clock after the period that sent it, and received at the
// period's receive phase
logic        tx_go;
logic [7:0]  tx_b;

// ---------------------------------------------------------------- registers
logic iocr_q;
logic [1:0] rx_ph;
logic       upd;                        // MAME's update_irq_states, on the registers it sees
always_ff @(posedge clk) begin
    logic [7:0] ls;
    restart <= 1'b0;
    tx_go <= 1'b0;
    upd <= rx_ph[1];
    iocr_q <= iocr_b1;
    if (iocr_q != iocr_b1) restart <= 1'b1;
    ls = regs[R_LS];

    // the transmitter at the period, the receiver two clocks later: MAME's callback sends first,
    // and the DS1991's reply to that byte (queued the clock after tx_go) is received in the same
    // callback
    rx_ph <= {rx_ph[0], period};
    if (period) begin
        if (regs[R_TXC][7]) begin
            if (!ls[2]) begin tx_go <= 1'b1; tx_b <= txbuf; ls[2] = 1'b1; ls[1] = 1'b0; end
            else if (!ls[1]) ls[1] = 1'b1;
        end
    end
    if (rx_ph[1]) begin
        if (regs[R_RXC][7] && !rq_empty) begin
            rq_out <= rq_out + 4'd1;
            if (!ls[7]) begin rxbuf <= rq[rq_out]; ls[7] = 1'b1; end
            else ls[5] = 1'b1;
        end
    end

    if (req) begin
        if (we) case (addr)
            R_LS: begin ls = ls & ~(wdata & 8'hF8); upd <= 1'b1; end
            R_RXC, R_TXC: begin
                upd <= 1'b1;
                if (((regs[R_RXC] | regs[R_TXC]) ^ (addr == R_RXC ? (wdata | regs[R_TXC]) : (wdata | regs[R_RXC]))) & 8'h80)
                    restart <= 1'b1;
                regs[addr] <= wdata;
            end
            R_BRDH, R_BRDL: begin if (wdata != regs[addr]) restart <= 1'b1; regs[addr] <= wdata; end
            R_CTL: begin if ((regs[R_CTL] ^ wdata) & 8'h09) restart <= 1'b1; regs[addr] <= wdata; end
            R_BUF: begin txbuf <= wdata; ls[2] = 1'b0; end
            default: if (addr < 4'd9) regs[addr] <= wdata;
        endcase
        else begin
            if (addr == R_BUF) begin rdata <= rxbuf; ls[7] = 1'b0; end
            else rdata <= (addr < 4'd9) ? ((addr == R_LS) ? regs[R_LS] : regs[addr]) : 8'hFF;
        end
    end
    regs[R_LS] <= ls;

    // the DS1991's reply to a transmitted byte
    if (tx_go) begin
        if (!ib_sub) begin
            case (tx_b)
            8'hC1: begin rq[rq_in] <= 8'hCD; rq_in <= rq_in + 4'd1; end
            8'hE1, 8'hE3: ;
            8'h66: begin rq[rq_in] <= 8'h66; rq_in <= rq_in + 4'd1; ib_sub <= 1'b1; ib_ptr <= 7'd0; end
            8'hCC: begin rq[rq_in] <= 8'hCC; rq_in <= rq_in + 4'd1; end
            default: bad <= 1'b1;
            endcase
        end else begin
            // the two command bytes are echoed, then the subkey's 64 bytes (zeros for subkey 3)
            rq[rq_in] <= (ib_ptr < 7'd2) ? tx_b : (ib_key == 2'd3) ? 8'h00 : dg_q;
            rq_in <= rq_in + 4'd1;
            if (ib_ptr == 7'd0) ib_key <= tx_b[7:6];
            ib_ptr <= ib_ptr + 7'd1;
            if (ib_ptr == 7'h41) ib_sub <= 1'b0;
        end
    end
    if (rq_in + 4'd1 == rq_out && tx_go) bad <= 1'b1;   // MAME: a receive-buffer overrun is fatal

    if (reset) begin
        for (int i = 0; i < 9; i++) regs[i] <= 8'h00;
        regs[R_LS] <= 8'h06;
        rq_in <= 4'd0; rq_out <= 4'd0; ib_sub <= 1'b0; bad <= 1'b0; rdata <= 8'h00;
    end
end

always_ff @(posedge clk) begin
    if (upd) begin
        irq_rx <= ((regs[R_RXC] & 8'h60) == 8'h20 && regs[R_LS][7]) || (regs[R_RXC][4] && (regs[R_LS] & 8'h78) != 0);
        irq_tx <= ((regs[R_TXC] & 8'h60) == 8'h20 && regs[R_LS][2]) || (regs[R_TXC][4] && regs[R_LS][1]);
    end
    if (reset) begin irq_rx <= 1'b0; irq_tx <= 1'b0; end
end

endmodule
