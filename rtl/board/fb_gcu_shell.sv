// SPDX-License-Identifier: GPL-3.0-or-later
//
// K057714 GCU's register file and VRAM ports as MAME's k057714.cpp reads and writes them; fb_gcu
// executes what they collect.
//
// Registers (0x7E800000-0x7E8000FF, 32-bit with byte enables): 0x00-0x08 the CRTC, 0x10 IRQ control
// (high half) and layer select (low), 0x14/0x18 alphas, 0x1C media bus, 0x20-0x2C origins, 0x30-0x3C
// sizes, 0x40-0x4C bases, 0x54/0x58 external FIFO, 0x5C VRAM read address, 0x60/0x64 write port
// addresses, 0x68 port modes, 0x6C, 0x70/0x74 the write ports. A port write in a mode with bit 8 set
// collects a command word (the four go to fb_gcu when the fourth arrives); otherwise it is a VRAM
// word at the port's address, which then advances. Addresses written are byte addresses of 16-bit
// pixels: the 32-bit word index is the value / 2 (& 0xFFFFFF first). Words and commands enter
// fb_gcu's queue in the order written; a port write waits while the queue is full.
//
// Reads: 0x80-0xFC the VRAM words from the read address on, once the queue has drained; 0x78 status:
// 0xFFFF0005 as MAME's, except that bits 1:0 (port 0) or 3:2 (port 1), the ready fields the code
// polls (FFF863D8, 80042A88), read 0 while a DMA transfer feeds that port (fb_board, dma_hold low);
// anything else 0xFFFFFFFF.
//
// vblank: at its start the IRQ rises if IRQ control bit 0 is set; a write of IRQ control with
// bit 0 clear drops it.
//
// The display registers go to fb_gcu_disp as written; reset gives them device_reset's values
// (G:83-125): the CRTC at the table's mode 0, 640 x 480, every context empty with alpha 16.

module fb_gcu_shell (
    input  logic        clk,
    input  logic        reset,

    input  logic        req,            // held until ack
    input  logic        we,
    input  logic [7:0]  addr,           // byte offset, word aligned
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic        ack,
    output logic [31:0] rdata,

    input  logic        dg_we,          // the DMA's direct path: a word to port dg_port's FIFO
    input  logic        dg_port,
    input  logic [31:0] dg_data,
    output logic        dg_ready,

    input  logic        vblank,
    input  logic        busy0,          // a DMA transfer feeds port 0 / 1 (status bits 1:0 / 3:2 read 0)
    input  logic        busy1,
    output logic        irq,

    output logic        cmd_v,          // a command's four words, as fb_gcu receives them
    output logic        cmd_port,
    output logic [127:0] cmd,

    // VRAM: fb_gcu's wide hornet_ddr3 master
    output logic        m_read,
    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [3:0]  m_be,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_be_hi,
    output logic [31:0] m_wdata_hi,
    input  logic        m_waitn,
    input  logic        m_rvalid,
    input  logic [31:0] m_rdata,
    input  logic [31:0] m_rdata_hi,
    output logic        gcu_idle,

    output logic [2:0][31:0] crtc,      // registers 0x00-0x08 as written
    output logic [15:0] ctrl_lo,        // register 0x10's low half, the layer select
    output logic [3:0][15:0] fr_alpha,  // 0x14/0x18, context 0 in 0x14's high half
    output logic [3:0][15:0] fr_x,      // 0x20-0x2C low halves
    output logic [3:0][15:0] fr_y,      // ... high halves
    output logic [3:0][15:0] fr_w,      // 0x30-0x3C low halves
    output logic [3:0][15:0] fr_h,      // ... high halves
    output logic [3:0][31:0] fr_base,   // 0x40-0x4C
    output logic [15:0] reg_6c,
    input  logic [5:0]  st_a,           // [Firebeat] the state dump's register block (end of file)
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd
);

logic [2:0][31:0] crtc_r;
logic [15:0] layer;
logic [23:0] rd_addr, p0_addr, p1_addr;
logic [15:0] mode0, mode1, irqctrl;
logic [31:0] c0 [4], c1 [4];
logic [1:0]  c0n, c1n;

wire [31:0] mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};

// the engine's queue: {2'd0, 73'd0, index, word} a VRAM word, {2'd1, cmd} a command
logic         q_push;
logic [129:0] q_in;
logic         q_ready, e_idle;
logic         r_on, r_ack;
logic [22:0]  r_a;
logic [31:0]  r_d;

fb_gcu u_eng (
    .clk, .reset, .push(q_push), .push_d(q_in), .ready(q_ready), .idle(e_idle),
    .rw_req(r_on && e_idle), .rw_addr(r_a), .rw_ack(r_ack), .rw_data(r_d),
    .m_read, .m_write, .m_addr, .m_burst, .m_be, .m_wdata, .m_be_hi, .m_wdata_hi,
    .m_waitn, .m_rvalid, .m_rdata, .m_rdata_hi
);
assign gcu_idle = e_idle;

wire q_full = !q_ready;

assign dg_ready = !q_full && !q_push;

logic vb_q;
always_ff @(posedge clk) begin
    ack <= 1'b0;
    cmd_v <= 1'b0;
    q_push <= 1'b0;
    vb_q <= vblank;
    if (vblank && !vb_q && irqctrl[0]) irq <= 1'b1;
    if (r_ack) begin r_on <= 1'b0; rdata <= r_d; ack <= 1'b1; end

    if (req && !ack && !r_on) begin
        if (!we) begin
            if (addr[7]) begin r_on <= 1'b1; r_a <= 23'(rd_addr + {19'd0, addr[6:2]}); end
            else begin
                rdata <= (addr == 8'h78) ? {28'hFFFF_000, busy1 ? 2'b00 : 2'b01, busy0 ? 2'b00 : 2'b01} : 32'hFFFF_FFFF;
                ack <= 1'b1;
            end
        end else if ((addr == 8'h70 || addr == 8'h74) && (q_full || q_push)) ;
        else begin
            ack <= 1'b1;
            if (addr <= 8'h08) crtc_r[addr[3:2]] <= (crtc_r[addr[3:2]] & ~mask) | (wdata & mask);
            if (addr == 8'h10 && be[1:0] != 2'b00) layer <= wdata[15:0];
            if (addr == 8'h14 || addr == 8'h18) begin
                if (be[3:2] != 2'b00) fr_alpha[{addr[3], 1'b0}] <= wdata[31:16];
                if (be[1:0] != 2'b00) fr_alpha[{addr[3], 1'b1}] <= wdata[15:0];
            end
            if (addr[7:4] == 4'h2 || addr[7:4] == 4'h3) begin
                if (be[3:2] != 2'b00) begin if (addr[4]) fr_h[addr[3:2]] <= wdata[31:16]; else fr_y[addr[3:2]] <= wdata[31:16]; end
                if (be[1:0] != 2'b00) begin if (addr[4]) fr_w[addr[3:2]] <= wdata[15:0]; else fr_x[addr[3:2]] <= wdata[15:0]; end
            end
            if (addr[7:4] == 4'h4) fr_base[addr[3:2]] <= wdata;
            if (addr == 8'h6C && be[1:0] != 2'b00) reg_6c <= wdata[15:0];
            case (addr)
            8'h10: if (be[3:2] != 2'b00) begin
                       if (!wdata[16]) irq <= 1'b0;
                       irqctrl <= wdata[31:16];
                   end
            8'h5C: rd_addr <= {1'b0, wdata[23:1]};
            8'h60: p0_addr <= {1'b0, wdata[23:1]};
            8'h64: p1_addr <= {1'b0, wdata[23:1]};
            8'h68: begin if (be[3:2] != 2'b00) mode0 <= wdata[31:16]; if (be[1:0] != 2'b00) mode1 <= wdata[15:0]; end
            8'h70:
                if (mode0[8]) begin
                    c0[c0n] <= wdata; c0n <= c0n + 2'd1;
                    if (c0n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b0; cmd <= {c0[0], c0[1], c0[2], wdata}; q_push <= 1'b1; q_in <= {2'd1, c0[0], c0[1], c0[2], wdata}; end
                end else begin
                    q_push <= 1'b1; q_in <= {2'd0, 73'd0, p0_addr[22:0], wdata}; p0_addr <= p0_addr + 24'd1;
                end
            8'h74:
                if (mode1[8]) begin
                    c1[c1n] <= wdata; c1n <= c1n + 2'd1;
                    if (c1n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b1; cmd <= {c1[0], c1[1], c1[2], wdata}; q_push <= 1'b1; q_in <= {2'd1, c1[0], c1[1], c1[2], wdata}; end
                end else begin
                    q_push <= 1'b1; q_in <= {2'd0, 73'd0, p1_addr[22:0], wdata}; p1_addr <= p1_addr + 24'd1;
                end
            default: ;
            endcase
        end
    end

    // the DMA's words, as writes of register 0x70 / 0x74 (the bus is idle meanwhile: the CPU is held)
    if (dg_we) begin
        if (!dg_port) begin
            if (mode0[8]) begin
                c0[c0n] <= dg_data; c0n <= c0n + 2'd1;
                if (c0n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b0; cmd <= {c0[0], c0[1], c0[2], dg_data}; q_push <= 1'b1; q_in <= {2'd1, c0[0], c0[1], c0[2], dg_data}; end
            end else begin q_push <= 1'b1; q_in <= {2'd0, 73'd0, p0_addr[22:0], dg_data}; p0_addr <= p0_addr + 24'd1; end
        end else begin
            if (mode1[8]) begin
                c1[c1n] <= dg_data; c1n <= c1n + 2'd1;
                if (c1n == 2'd3) begin cmd_v <= 1'b1; cmd_port <= 1'b1; cmd <= {c1[0], c1[1], c1[2], dg_data}; q_push <= 1'b1; q_in <= {2'd1, c1[0], c1[1], c1[2], dg_data}; end
            end else begin q_push <= 1'b1; q_in <= {2'd0, 73'd0, p1_addr[22:0], dg_data}; p1_addr <= p1_addr + 24'd1; end
        end
    end

    if (reset) begin
        irq <= 1'b0; irqctrl <= 16'h0; mode0 <= 16'h0; mode1 <= 16'h0; c0n <= 2'd0; c1n <= 2'd0;
        r_on <= 1'b0; rd_addr <= '0; p0_addr <= '0; p1_addr <= '0;
        crtc_r[0] <= {16'd639, 8'd15, 8'd47};
        crtc_r[1] <= {16'd479, 8'd9, 8'd32};
        crtc_r[2] <= {8'd95, 8'd1, 16'd0};
        for (int f = 0; f < 4; f++) begin
            fr_base[f] <= '0; fr_w[f] <= '0; fr_h[f] <= '0; fr_alpha[f] <= 16'h0840;      // alpha 1 and 2 at 16, blend mode 0
        end
        reg_6c <= '0;
    end
`ifdef VERILATOR  // st_lists: write
    if (st_we) case (st_a)
    6'h0: ack <= ($bits(ack))'(st_wd);
    6'h1: cmd_v <= ($bits(cmd_v))'(st_wd);
    6'h2: q_push <= ($bits(q_push))'(st_wd);
    6'h3: vb_q <= ($bits(vb_q))'(st_wd);
    6'h4: irq <= ($bits(irq))'(st_wd);
    6'h5: r_on <= ($bits(r_on))'(st_wd);
    6'h6: rdata <= ($bits(rdata))'(st_wd);
    6'h7: r_a <= ($bits(r_a))'(st_wd);
    6'h8: crtc_r[0] <= ($bits(crtc_r[0]))'(st_wd);
    6'h9: crtc_r[1] <= ($bits(crtc_r[1]))'(st_wd);
    6'hA: crtc_r[2] <= ($bits(crtc_r[2]))'(st_wd);
    6'hB: layer <= ($bits(layer))'(st_wd);
    6'hC: fr_alpha[0] <= ($bits(fr_alpha[0]))'(st_wd);
    6'hD: fr_alpha[1] <= ($bits(fr_alpha[1]))'(st_wd);
    6'hE: fr_alpha[2] <= ($bits(fr_alpha[2]))'(st_wd);
    6'hF: fr_alpha[3] <= ($bits(fr_alpha[3]))'(st_wd);
    6'h10: fr_h[0] <= ($bits(fr_h[0]))'(st_wd);
    6'h11: fr_h[1] <= ($bits(fr_h[1]))'(st_wd);
    6'h12: fr_h[2] <= ($bits(fr_h[2]))'(st_wd);
    6'h13: fr_h[3] <= ($bits(fr_h[3]))'(st_wd);
    6'h14: fr_y[0] <= ($bits(fr_y[0]))'(st_wd);
    6'h15: fr_y[1] <= ($bits(fr_y[1]))'(st_wd);
    6'h16: fr_y[2] <= ($bits(fr_y[2]))'(st_wd);
    6'h17: fr_y[3] <= ($bits(fr_y[3]))'(st_wd);
    6'h18: fr_w[0] <= ($bits(fr_w[0]))'(st_wd);
    6'h19: fr_w[1] <= ($bits(fr_w[1]))'(st_wd);
    6'h1A: fr_w[2] <= ($bits(fr_w[2]))'(st_wd);
    6'h1B: fr_w[3] <= ($bits(fr_w[3]))'(st_wd);
    6'h1C: fr_x[0] <= ($bits(fr_x[0]))'(st_wd);
    6'h1D: fr_x[1] <= ($bits(fr_x[1]))'(st_wd);
    6'h1E: fr_x[2] <= ($bits(fr_x[2]))'(st_wd);
    6'h1F: fr_x[3] <= ($bits(fr_x[3]))'(st_wd);
    6'h20: fr_base[0] <= ($bits(fr_base[0]))'(st_wd);
    6'h21: fr_base[1] <= ($bits(fr_base[1]))'(st_wd);
    6'h22: fr_base[2] <= ($bits(fr_base[2]))'(st_wd);
    6'h23: fr_base[3] <= ($bits(fr_base[3]))'(st_wd);
    6'h24: reg_6c <= ($bits(reg_6c))'(st_wd);
    6'h25: irqctrl <= ($bits(irqctrl))'(st_wd);
    6'h26: rd_addr <= ($bits(rd_addr))'(st_wd);
    6'h27: p0_addr <= ($bits(p0_addr))'(st_wd);
    6'h28: p1_addr <= ($bits(p1_addr))'(st_wd);
    6'h29: mode0 <= ($bits(mode0))'(st_wd);
    6'h2A: mode1 <= ($bits(mode1))'(st_wd);
    6'h2B: c0[0] <= ($bits(c0[0]))'(st_wd);
    6'h2C: c0[1] <= ($bits(c0[1]))'(st_wd);
    6'h2D: c0[2] <= ($bits(c0[2]))'(st_wd);
    6'h2E: c0[3] <= ($bits(c0[3]))'(st_wd);
    6'h2F: c0n <= ($bits(c0n))'(st_wd);
    6'h30: cmd_port <= ($bits(cmd_port))'(st_wd);
    6'h31: cmd[31:0] <= ($bits(cmd[31:0]))'(st_wd);
    6'h32: cmd[63:32] <= ($bits(cmd[63:32]))'(st_wd);
    6'h33: cmd[95:64] <= ($bits(cmd[95:64]))'(st_wd);
    6'h34: cmd[127:96] <= ($bits(cmd[127:96]))'(st_wd);
    6'h35: q_in[31:0] <= ($bits(q_in[31:0]))'(st_wd);
    6'h36: q_in[63:32] <= ($bits(q_in[63:32]))'(st_wd);
    6'h37: q_in[95:64] <= ($bits(q_in[95:64]))'(st_wd);
    6'h38: q_in[127:96] <= ($bits(q_in[127:96]))'(st_wd);
    6'h39: q_in[129:128] <= ($bits(q_in[129:128]))'(st_wd);
    6'h3A: c1[0] <= ($bits(c1[0]))'(st_wd);
    6'h3B: c1[1] <= ($bits(c1[1]))'(st_wd);
    6'h3C: c1[2] <= ($bits(c1[2]))'(st_wd);
    6'h3D: c1[3] <= ($bits(c1[3]))'(st_wd);
    6'h3E: c1n <= ($bits(c1n))'(st_wd);
    default: ;
    endcase
`endif  // st_lists: write
end

assign crtc = crtc_r;
assign ctrl_lo = layer;

// st_lists: begin
// [Firebeat] The state dump's register block (docs/STATE.md), generated by scripts/st_lists.py:
// a word a register, in the order of its always_ff block; written in Verilator only.
always_comb begin
    st_d = 32'd0;
    case (st_a)
    6'h0: st_d = 32'(ack);
    6'h1: st_d = 32'(cmd_v);
    6'h2: st_d = 32'(q_push);
    6'h3: st_d = 32'(vb_q);
    6'h4: st_d = 32'(irq);
    6'h5: st_d = 32'(r_on);
    6'h6: st_d = 32'(rdata);
    6'h7: st_d = 32'(r_a);
    6'h8: st_d = 32'(crtc_r[0]);
    6'h9: st_d = 32'(crtc_r[1]);
    6'hA: st_d = 32'(crtc_r[2]);
    6'hB: st_d = 32'(layer);
    6'hC: st_d = 32'(fr_alpha[0]);
    6'hD: st_d = 32'(fr_alpha[1]);
    6'hE: st_d = 32'(fr_alpha[2]);
    6'hF: st_d = 32'(fr_alpha[3]);
    6'h10: st_d = 32'(fr_h[0]);
    6'h11: st_d = 32'(fr_h[1]);
    6'h12: st_d = 32'(fr_h[2]);
    6'h13: st_d = 32'(fr_h[3]);
    6'h14: st_d = 32'(fr_y[0]);
    6'h15: st_d = 32'(fr_y[1]);
    6'h16: st_d = 32'(fr_y[2]);
    6'h17: st_d = 32'(fr_y[3]);
    6'h18: st_d = 32'(fr_w[0]);
    6'h19: st_d = 32'(fr_w[1]);
    6'h1A: st_d = 32'(fr_w[2]);
    6'h1B: st_d = 32'(fr_w[3]);
    6'h1C: st_d = 32'(fr_x[0]);
    6'h1D: st_d = 32'(fr_x[1]);
    6'h1E: st_d = 32'(fr_x[2]);
    6'h1F: st_d = 32'(fr_x[3]);
    6'h20: st_d = 32'(fr_base[0]);
    6'h21: st_d = 32'(fr_base[1]);
    6'h22: st_d = 32'(fr_base[2]);
    6'h23: st_d = 32'(fr_base[3]);
    6'h24: st_d = 32'(reg_6c);
    6'h25: st_d = 32'(irqctrl);
    6'h26: st_d = 32'(rd_addr);
    6'h27: st_d = 32'(p0_addr);
    6'h28: st_d = 32'(p1_addr);
    6'h29: st_d = 32'(mode0);
    6'h2A: st_d = 32'(mode1);
    6'h2B: st_d = 32'(c0[0]);
    6'h2C: st_d = 32'(c0[1]);
    6'h2D: st_d = 32'(c0[2]);
    6'h2E: st_d = 32'(c0[3]);
    6'h2F: st_d = 32'(c0n);
    6'h30: st_d = 32'(cmd_port);
    6'h31: st_d = 32'(cmd[31:0]);
    6'h32: st_d = 32'(cmd[63:32]);
    6'h33: st_d = 32'(cmd[95:64]);
    6'h34: st_d = 32'(cmd[127:96]);
    6'h35: st_d = 32'(q_in[31:0]);
    6'h36: st_d = 32'(q_in[63:32]);
    6'h37: st_d = 32'(q_in[95:64]);
    6'h38: st_d = 32'(q_in[127:96]);
    6'h39: st_d = 32'(q_in[129:128]);
    6'h3A: st_d = 32'(c1[0]);
    6'h3B: st_d = 32'(c1[1]);
    6'h3C: st_d = 32'(c1[2]);
    6'h3D: st_d = 32'(c1[3]);
    6'h3E: st_d = 32'(c1n);
    default: ;
    endcase
end
// st_lists: end

endmodule
