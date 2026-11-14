// SPDX-License-Identifier: GPL-3.0-or-later
//
// One NS16550 channel as MAME's ins8250.cpp models it (ns16550_device): the registers, the 16-byte
// receive and transmit FIFOs, a transmitter and receiver at the divisor's rate from a 24 MHz
// clock enable (Keyboardmania's duart_midi, firebeat.cpp:1852-1864), 8N1 framing.
//
// The interrupt line: MAME calls the channel's out_int callback at every update_interrupt, with
// the line's state at that point, and Keyboardmania's callbacks act on each call, not on changes
// (firebeat.cpp:1903-1925). So every register access or event that runs update_interrupt pulses
// int_upd, with int_hi set if any of its calls saw the line high and int_q the last call's state.
//
// Not modelled: loopback (MCR bit 4), break, parity, the modem inputs (MSR reads 0), 5-7 data bits.
// The FIFO timeout fires dl/2 24 MHz clocks after a byte arrives or is read, MAME's set_timer()
// (ins8250.h:129; docs/MAME_KLUDGES.md).

module fb_ns16550 (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce24,           // 24 MHz; low throughout st_hold
    input  logic        req,            // a byte access, one clock
    input  logic        we,
    input  logic [2:0]  addr,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,          // the clock after req
    input  logic        rxd,
    output logic        txd,
    output logic        tx_v,           // a byte has gone out on txd (its stop bit sent)
    output logic [7:0]  tx_byte,
    output logic        int_upd,
    output logic        int_hi,
    output logic        int_q,
    input  logic        st_hold,        // [Firebeat] the FIFOs' read ports follow st_a; the CPU is stopped
    input  logic [6:0]  st_a,           // [Firebeat] the state dump's register block (end of file)
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd
);

localparam logic [4:0] P_RDA = 5'h01, P_THRE = 5'h02, P_LS = 5'h04, P_MS = 5'h08, P_TO = 5'h11;

logic [7:0]  ier, lcr, mcr, lsr, scr, rbr, thr, fcr;
logic [15:0] dl;
logic [4:0]  pend;
logic [3:0]  rlvl;                       // receive trigger level minus one
// One read port each, unregistered, so a pop and a transmit see their byte in the clock they run.
// Dump words 0x40-0x4F and 0x50-0x5F.
(* ramstyle = "MLAB, no_rw_check" *) logic [7:0] rfifo [16];
(* ramstyle = "MLAB, no_rw_check" *) logic [7:0] tfifo [16];
logic [15:0] efifo;                      // framing error of each received byte
logic [3:0]  rhead, rtail;
// [Firebeat] a fifth bit tells a full transmit FIFO from an empty one; MAME's 4-bit indices (ins8250.cpp
// push_tx) lose 16 bytes written behind a busy shift register, which kbm does on the board
logic [4:0]  thead, ttail;
wire         tfull = (thead ^ ttail) == 5'h10;
logic [4:0]  rnum;
// the transmitter: the bit clock runs from the last divisor write; a frame is 10 bits
logic [15:0] tdiv;                       // 24 MHz clocks to the next bit tick
logic [3:0]  tbit;                       // bits left in the frame; 0 idle
logic [9:0]  tsr;
logic [7:0]  tcur;                       // the byte in tsr
// the receiver: 16x oversampling from the start bit's falling edge
logic [15:0] rdiv;
logic [3:0]  rph;                        // sixteenths of a bit
logic [3:0]  rbit;                       // 0 idle, 1 start, 2-9 data, 10 stop
logic [7:0]  rsr;
logic        rxd_q;
logic [15:0] tmo;                        // FIFO timeout, 24 MHz clocks; 0 off

wire fifo_on = fcr[0];

wire rcomp = ce24 && rbit == 4'd10 && rdiv <= 16'd1 && rph == 4'd15;    // the stop bit sampled
wire rfe   = !rxd;
wire [7:0] rq = rfifo[st_hold ? st_a[3:0] : rtail];
wire [7:0] tq = tfifo[st_hold ? st_a[3:0] : ttail[3:0]];

always_ff @(posedge clk) begin
    if (rcomp && fifo_on && rnum != 5'd16) rfifo[rhead] <= rsr;
    if (req && we && addr == 3'd0 && !lcr[7] && fifo_on && !tfull) tfifo[thead[3:0]] <= wdata;
`ifdef VERILATOR
    if (st_we && st_a[6:4] == 3'b100) rfifo[st_a[3:0]] <= st_wd[7:0];
    if (st_we && st_a[6:4] == 3'b101) tfifo[st_a[3:0]] <= st_wd[7:0];
`endif
end

function automatic logic line(input logic [4:0] p, input logic [7:0] e);
    return (p[3:0] & e[3:0]) != 4'd0;
endfunction

always_ff @(posedge clk) begin
    logic [4:0] p;
    logic [7:0] l, e;
    logic       upd, hi, last;
    logic       tcomp, tick;
    p = pend; l = lsr; e = ier; upd = 1'b0; hi = 1'b0; last = 1'b0;
    tx_v <= 1'b0;

    // ------------------------------------------------ the bit clocks
    tcomp = 1'b0;
    if (ce24) begin
        tick = tdiv <= 16'd1;
        tdiv <= tick ? {dl[11:0], 4'h0} : tdiv - 16'd1;
        if (tick && tbit != 4'd0) begin
            txd <= tsr[0];
            tsr <= {1'b1, tsr[9:1]};
            tbit <= tbit - 4'd1;
            if (tbit == 4'd1) begin tcomp = 1'b1; tx_v <= 1'b1; tx_byte <= tcur; end
        end
        rxd_q <= rxd;
        if (rbit == 4'd0) begin
            if (rxd_q && !rxd) begin rbit <= 4'd1; rph <= 4'd0; rdiv <= dl; end
        end else if (rdiv <= 16'd1) begin
            rdiv <= dl;
            rph <= rph + 4'd1;
            if ((rbit == 4'd1 && rph == 4'd7) || (rbit != 4'd1 && rph == 4'd15)) begin
                rph <= 4'd0;
                if (rbit == 4'd1) rbit <= rxd ? 4'd0 : 4'd2;          // a glitch, not a start bit
                else if (rbit != 4'd10) begin rsr <= {rxd, rsr[7:1]}; rbit <= rbit + 4'd1; end
                else rbit <= 4'd0;
            end
        end else rdiv <= rdiv - 16'd1;
        if (tmo == 16'd1) begin p = p | P_TO; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
        if (tmo != 16'd0) tmo <= tmo - 16'd1;
    end

    // ------------------------------------------------ tra_complete
    if (tcomp) begin
        if (fifo_on) begin
            if (ttail != thead) begin
                tsr <= {1'b1, tq, 1'b0}; tcur <= tq; tbit <= 4'd10; ttail <= ttail + 5'd1; l[6] = 1'b0;
                if (ttail + 5'd1 == thead) begin l[5] = 1'b1; p = p | P_THRE; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
            end else l[6] = 1'b1;
        end else if (!l[5]) begin
            tsr <= {1'b1, thr, 1'b0}; tcur <= thr; tbit <= 4'd10; l[6] = 1'b0; l[5] = 1'b1;
            p = p | P_THRE; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
        end else l[6] = 1'b1;
    end

    // ------------------------------------------------ rcv_complete
    if (rcomp) begin
        if (fifo_on) begin
            if (rnum == 5'd16) begin
                l[1] = 1'b1; p = p | P_LS; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
            end else begin
                if (rnum == 5'd0 && rfe) begin l[3] = 1'b1; p = p | P_LS; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
                l[0] = 1'b1;
                efifo[rhead] <= rfe; rhead <= rhead + 4'd1; rnum <= rnum + 5'd1;
                if (rnum >= {1'b0, rlvl}) begin p = p | P_RDA; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
                tmo <= {1'b0, dl[15:1]};
            end
        end else begin
            if (l[0]) l[1] = 1'b1;
            l[0] = 1'b1;
            if (rfe) l[3] = 1'b1;
            if (l[4:1] != 4'd0) begin p = p | P_LS; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
            rbr <= rsr;
            p = p | P_RDA; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
        end
    end

    // ------------------------------------------------ the CPU's access
    if (req) begin
        if (we) case (addr)
        3'd0:
            if (lcr[7]) begin
                dl <= {dl[15:8], wdata}; tdiv <= {dl[11:8], wdata, 4'h0};
                if (!l[6]) begin tbit <= 4'd0; txd <= 1'b1; end      // update_baud_rate's tra_complete
            end else begin
                thr <= wdata; l[5] = 1'b0;
                if (fifo_on && !tfull) thead <= thead + 5'd1;
                p = p & ~P_THRE; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
                if (l[6]) begin                                       // tra_complete at once
                    if (fifo_on) begin
                        // the FIFO before this push was empty exactly when ttail == thead
                        logic [7:0] b;
                        b = (ttail == thead) ? wdata : tq;
                        tsr <= {1'b1, b, 1'b0}; tcur <= b; tbit <= 4'd10;
                        ttail <= ttail + 5'd1; l[6] = 1'b0;
                        if (ttail == thead) begin l[5] = 1'b1; p = p | P_THRE; hi = hi | line(p, e); last = line(p, e); end
                    end else begin
                        tsr <= {1'b1, wdata, 1'b0}; tcur <= wdata; tbit <= 4'd10; l[6] = 1'b0; l[5] = 1'b1;
                        p = p | P_THRE; hi = hi | line(p, e); last = line(p, e);
                    end
                end
            end
        3'd1:
            if (lcr[7]) begin
                dl <= {wdata, dl[7:0]}; tdiv <= {wdata[3:0], dl[7:0], 4'h0};
                if (!l[6]) begin tbit <= 4'd0; txd <= 1'b1; end
            end else begin
                if (l[5] && wdata[1]) begin p = p | P_THRE; hi = hi | line(p, e); end
                e = wdata;
                upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
            end
        3'd2:
            if (!wdata[0]) fcr <= 8'h00;
            else begin
                logic [7:0] d;
                d = wdata;
                if (!fcr[0]) d[2:1] = 2'b11;
                if (d[1]) begin
                    rhead <= 4'd0; rtail <= 4'd0; rnum <= 5'd0; tmo <= 16'd0;
                    p = p & ~(P_TO | P_RDA); upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
                end
                if (d[2]) begin
                    thead <= 5'd0; ttail <= 5'd0; l[5] = 1'b1;
                    p = p | P_THRE; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
                end
                rlvl <= (d[7:6] == 2'd0) ? 4'd0 : (d[7:6] == 2'd1) ? 4'd3 : (d[7:6] == 2'd2) ? 4'd7 : 4'd13;
                fcr <= d & 8'hC9;
            end
        3'd3: lcr <= wdata;
        3'd4: mcr <= {3'b000, wdata[4:0]};
        3'd5: begin
            l = (l & 8'h60) | (wdata & 8'h9F);
            p = p | (l[0] ? P_RDA : 5'h0) | ((l[4:1] != 4'd0) ? P_LS : 5'h0) | (l[5] ? P_THRE : 5'h0);
            upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
        end
        3'd6: begin p = p & ~P_MS; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
        default: scr <= wdata;
        endcase
        else case (addr)
        3'd0:
            if (lcr[7]) rdata <= dl[7:0];
            else if (fifo_on) begin                                   // pop_rx
                logic [4:0] n;
                n = rnum;
                p = p & ~5'h10; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
                if (n != 5'd0) begin
                    rdata <= rq; rbr <= rq;
                    rtail <= rtail + 4'd1; n = n - 5'd1;
                    if (n != 5'd0 && efifo[rtail + 4'd1]) begin l[3] = 1'b1; p = p | P_LS; hi = hi | line(p, e); last = line(p, e); end
                end else begin rdata <= 8'h00; rbr <= 8'h00; end
                rnum <= n;
                if (n <= {1'b0, rlvl}) begin p = p & ~P_RDA; hi = hi | line(p, e); last = line(p, e); end
                if (n != 5'd0) tmo <= {1'b0, dl[15:1]};
                else begin tmo <= 16'd0; l[0] = 1'b0; end
            end else begin
                rdata <= rbr;
                p = p & ~P_RDA; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
                l[0] = 1'b0;
            end
        3'd1: rdata <= lcr[7] ? dl[15:8] : {4'h0, ier[3:0]};
        3'd2: begin
            logic [3:0] lo;
            lo = !line(pend, ier) ? 4'b0001
               : (ier[2] && pend[2]) ? 4'b0110
               : (ier[0] && pend[0]) ? {pend[4], 3'b100}
               : (ier[1] && pend[1]) ? 4'b0010 : 4'b0000;
            rdata <= {fifo_on ? 2'b11 : 2'b00, 2'b00, lo};
            if (lo == 4'b0010) begin p = p & ~P_THRE; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
        end
        3'd3: rdata <= lcr;
        3'd4: rdata <= mcr;
        3'd5: begin
            rdata <= lsr;
            if (lsr[4:1] != 4'd0) begin
                l = l & 8'hE1; p = p & ~P_LS; upd = 1'b1; hi = hi | line(p, e); last = line(p, e);
            end
        end
        3'd6: begin rdata <= 8'h00; p = p & ~P_MS; upd = 1'b1; hi = hi | line(p, e); last = line(p, e); end
        default: rdata <= scr;
        endcase
    end

    pend <= p; lsr <= l; ier <= e;
    int_upd <= upd; int_hi <= hi; int_q <= last;

    if (reset) begin
        ier <= 8'h00; lcr <= 8'h00; mcr <= 8'h00; lsr <= 8'h60; scr <= 8'h00; fcr <= 8'h00;
        dl <= 16'h0000; pend <= 5'h00; rlvl <= 4'd0; rbr <= 8'h00; thr <= 8'h00;
        rhead <= 4'd0; rtail <= 4'd0; rnum <= 5'd0; thead <= 5'd0; ttail <= 5'd0;
        tdiv <= 16'd0; tbit <= 4'd0; tsr <= 10'h3FF; tcur <= 8'h00; txd <= 1'b1; tx_byte <= 8'h00;
        rdiv <= 16'd0; rph <= 4'd0; rbit <= 4'd0; rsr <= 8'h00; rxd_q <= 1'b1; tmo <= 16'd0;
        int_upd <= 1'b1; int_hi <= 1'b0; int_q <= 1'b0;
    end
`ifdef VERILATOR  // st_lists: write
    if (st_we) case (st_a)
    7'h0: tx_v <= ($bits(tx_v))'(st_wd);
    7'h1: tdiv <= ($bits(tdiv))'(st_wd);
    7'h2: txd <= ($bits(txd))'(st_wd);
    7'h3: tsr <= ($bits(tsr))'(st_wd);
    7'h4: tbit <= ($bits(tbit))'(st_wd);
    7'h5: tx_byte <= ($bits(tx_byte))'(st_wd);
    7'h6: rbit <= ($bits(rbit))'(st_wd);
    7'h7: rph <= ($bits(rph))'(st_wd);
    7'h8: rdiv <= ($bits(rdiv))'(st_wd);
    7'h9: rsr <= ($bits(rsr))'(st_wd);
    7'hA: tmo <= ($bits(tmo))'(st_wd);
    7'hB: tcur <= ($bits(tcur))'(st_wd);
    7'hC: ttail <= ($bits(ttail))'(st_wd);
    7'hD: efifo <= ($bits(efifo))'(st_wd);
    7'hE: rhead <= ($bits(rhead))'(st_wd);
    7'hF: rnum <= ($bits(rnum))'(st_wd);
    7'h10: dl <= ($bits(dl))'(st_wd);
    7'h11: thr <= ($bits(thr))'(st_wd);
    7'h12: thead <= ($bits(thead))'(st_wd);
    7'h13: fcr <= ($bits(fcr))'(st_wd);
    7'h14: rtail <= ($bits(rtail))'(st_wd);
    7'h15: lcr <= ($bits(lcr))'(st_wd);
    7'h16: mcr <= ($bits(mcr))'(st_wd);
    7'h17: scr <= ($bits(scr))'(st_wd);
    7'h18: rdata <= ($bits(rdata))'(st_wd);
    7'h19: rbr <= ($bits(rbr))'(st_wd);
    7'h1A: lsr <= ($bits(lsr))'(st_wd);
    7'h1B: ier <= ($bits(ier))'(st_wd);
    7'h1C: int_upd <= ($bits(int_upd))'(st_wd);
    7'h1D: int_hi <= ($bits(int_hi))'(st_wd);
    7'h1E: int_q <= ($bits(int_q))'(st_wd);
    7'h1F: pend <= ($bits(pend))'(st_wd);
    7'h20: rlvl <= ($bits(rlvl))'(st_wd);
    7'h21: rxd_q <= ($bits(rxd_q))'(st_wd);
    default: ;
    endcase
`endif  // st_lists: write
end

// st_lists: begin
// [Firebeat] The state dump's register block (docs/STATE.md), generated by scripts/st_lists.py:
// a word a register, in the order of its always_ff block; written in Verilator only.
always_comb begin
    st_d = 32'd0;
    case (st_a)
    7'h0: st_d = 32'(tx_v);
    7'h1: st_d = 32'(tdiv);
    7'h2: st_d = 32'(txd);
    7'h3: st_d = 32'(tsr);
    7'h4: st_d = 32'(tbit);
    7'h5: st_d = 32'(tx_byte);
    7'h6: st_d = 32'(rbit);
    7'h7: st_d = 32'(rph);
    7'h8: st_d = 32'(rdiv);
    7'h9: st_d = 32'(rsr);
    7'hA: st_d = 32'(tmo);
    7'hB: st_d = 32'(tcur);
    7'hC: st_d = 32'(ttail);
    7'hD: st_d = 32'(efifo);
    7'hE: st_d = 32'(rhead);
    7'hF: st_d = 32'(rnum);
    7'h10: st_d = 32'(dl);
    7'h11: st_d = 32'(thr);
    7'h12: st_d = 32'(thead);
    7'h13: st_d = 32'(fcr);
    7'h14: st_d = 32'(rtail);
    7'h15: st_d = 32'(lcr);
    7'h16: st_d = 32'(mcr);
    7'h17: st_d = 32'(scr);
    7'h18: st_d = 32'(rdata);
    7'h19: st_d = 32'(rbr);
    7'h1A: st_d = 32'(lsr);
    7'h1B: st_d = 32'(ier);
    7'h1C: st_d = 32'(int_upd);
    7'h1D: st_d = 32'(int_hi);
    7'h1E: st_d = 32'(int_q);
    7'h1F: st_d = 32'(pend);
    7'h20: st_d = 32'(rlvl);
    7'h21: st_d = 32'(rxd_q);
    default: st_d = st_a[6] ? 32'(st_a[4] ? tq : rq) : 32'd0;
    endcase
end
// st_lists: end

endmodule
