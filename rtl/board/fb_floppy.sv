// SPDX-License-Identifier: GPL-3.0-or-later
//
// BM3: the FDC37C665GT's floppy controller and its 3.5" HD drive (ROADMAP Phase 10 step 9). The
// controller is ao486_MiSTer's `floppy.v` (82077-class, vendored unchanged in ao486_floppy/); this
// wrapper adds what the FDC37C665GT has around it and serves its sectors from an hps_io drive.
//
//   0x3F0, 0x3F1  configuration mode (0x55 0x55 in, 0xAA out) and its registers: writes ignored,
//                 reads 0, as the no-disk model this replaced
//   0x3F2-0x3F7   floppy.v's DOR, MSR/DSR, FIFO, DIR/CCR
//
// The image: a raw 1.44 MB, 1.2 MB or 720 KB file; another size mounts as no disk. floppy.v asks
// for one 512-byte sector at a time (`request`), and each is one hps_io transfer: BLKSZ 2 is 512
// bytes, the slot's block count 1 (Firebeat.sv sd_blk_cnt[2] = 0), and Main seeks to sd_lba * 512,
// so sd_lba is the sector's own LBA. bm3 moves data by programmed I/O (SPECIFY ND=1, HARDWARE_NOTES "bm3's
// floppy in MAME"); floppy.v's DMA port is tied off.
//
// The interrupt is a clock's pulse on floppy.v's line rising: the extend board latches it (fb_board,
// IRQ1 bit 2), as MAME's floppy_irq_callback acts on the rise only.

module fb_floppy #(
    parameter int CLK_HZ = 66_666_667
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        req,             // a byte access to 0x3F0 + port, one clock
    input  logic        we,
    input  logic [2:0]  port,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,           // the clock after req
    output logic        irq,

    input  logic        img_mounted,     // hps_io, this drive's bit
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,    // 16-bit words; a 512-byte transfer uses 0-255
    input  logic [15:0] sd_buff_dout,
    input  logic        sd_buff_wr,
    output logic [15:0] sd_buff_din
);

// ---------------------------------------------------------------- configuration mode
logic       cfg = 1'b0;
logic [1:0] k55 = 2'd0;
logic       cfg_rd = 1'b0;               // the read being answered is 0x3F0/0x3F1's
always_ff @(posedge clk) begin
    if (req) begin
        cfg_rd <= !we && port[2:1] == 2'b00;
    end
    if (req && we && port == 3'd0) begin
        if (wdata == 8'h55) begin
            if (k55 == 2'd1) begin
                cfg <= 1'b1;
            end
            k55 <= k55 + 2'd1;
        end
        else begin
            k55 <= 2'd0;
            if (wdata == 8'hAA) begin
                cfg <= 1'b0;
            end
        end
    end
    if (reset) begin
        cfg <= 1'b0;
        k55 <= 2'd0;
    end
end

// ---------------------------------------------------------------- the controller
wire        fio = req && port[2:1] != 2'b00;
logic [7:0] f_q;
logic       f_irq, f_irq_q;
logic [3:0] m_addr;
logic       m_write, m_read;
logic [15:0] m_wd;
wire  [15:0] m_rd;
wire  [1:0]  f_request;

floppy u_fdc (
    .clk, .rst_n(!reset),
    .dma_req(), .dma_ack(1'b0), .dma_tc(1'b0), .dma_readdata(8'h00), .dma_writedata(),
    .irq(f_irq),
    .io_address(port), .io_read(fio && !we), .io_readdata(f_q), .io_write(fio && we), .io_writedata(wdata),
    .fdd0_inserted(),
    .mgmt_address(m_addr), .mgmt_fddn(1'b0), .mgmt_write(m_write), .mgmt_writedata(m_wd),
    .mgmt_read(m_read), .mgmt_readdata(m_rd),
    .wp(2'b00), .clock_rate(28'(CLK_HZ)), .request(f_request)
);

assign rdata = cfg_rd ? 8'h00 : f_q;

always_ff @(posedge clk) begin
    f_irq_q <= f_irq;
    irq <= f_irq && !f_irq_q;
end

// ---------------------------------------------------------------- the block buffer
logic [15:0] blk [256];
logic [7:0]  b_wa, b_ra;
logic [15:0] b_wd, b_q;
logic        b_we;
always_ff @(posedge clk) begin
    if (b_we) begin
        blk[b_wa] <= b_wd;
    end
    b_q <= blk[b_ra];
end
assign sd_buff_din = b_q;

// ---------------------------------------------------------------- media and sectors
typedef enum logic [3:0] {
    M_IDLE, M_MEDIA, M_SEC, M_RD, M_FILL, M_FILLW, M_DRAIN, M_DRAINW, M_WR, M_DONE
} m_t;
m_t          ms = M_IDLE;
logic [2:0]  mi = 3'd0;                       // media register being written
logic        present, wprot;
logic [7:0]  m_spt;
logic [15:0] m_count;
logic        wr_op;                      // the sector being served is a write
logic [9:0]  bi;                         // byte index within the sector
logic [7:0]  lo;                         // a write's even byte, waiting for its odd one
logic        sd_busy;
logic        mnt = 1'b0;                 // a mount not yet given to floppy.v
logic [63:0] mnt_size;
logic        mnt_ro;

always_comb begin
    b_we = 1'b0;
    b_wa = sd_buff_addr[7:0];
    b_wd = sd_buff_dout;
    if (ms == M_RD && sd_buff_wr) begin
        b_we = 1'b1;
    end
    if (ms == M_DRAINW && bi[0]) begin
        b_we = 1'b1;
        b_wa = bi[8:1];
        b_wd = {m_rd[7:0], lo};
    end
    b_ra = (ms == M_FILL || ms == M_FILLW) ? bi[8:1] : sd_buff_addr[7:0];
end

always_ff @(posedge clk) begin
    m_write <= 1'b0;
    m_read <= 1'b0;
    if (img_mounted) begin
        mnt <= 1'b1;
        mnt_size <= img_size;
        mnt_ro <= img_readonly;
    end
    case (ms)
    M_IDLE: begin
        m_addr <= 4'd0;
        if (mnt) begin
            mnt <= 1'b0;
            present <= mnt_size == 64'd1474560 || mnt_size == 64'd1228800 || mnt_size == 64'd737280;
            wprot <= mnt_ro;
            m_spt <= mnt_size == 64'd1474560 ? 8'd18 : mnt_size == 64'd1228800 ? 8'd15 : 8'd9;
            m_count <= mnt_size[24:9];
            mi <= 3'd0;
            ms <= M_MEDIA;
        end
        else if (f_request != 2'b00) begin
            wr_op <= f_request[1];
            ms <= M_SEC;
        end
    end
    // media: absent first so a remount sets the disk-change bit, then the geometry, then present
    M_MEDIA: begin
        m_write <= 1'b1;
        case (mi)
        3'd0: begin m_addr <= 4'd0; m_wd <= 16'd0; end
        3'd1: begin m_addr <= 4'd1; m_wd <= {15'd0, wprot}; end
        3'd2: begin m_addr <= 4'd2; m_wd <= 16'd80; end
        3'd3: begin m_addr <= 4'd3; m_wd <= {8'd0, m_spt}; end
        3'd4: begin m_addr <= 4'd4; m_wd <= m_count; end
        3'd5: begin m_addr <= 4'd5; m_wd <= 16'd2; end
        default: begin m_addr <= 4'd0; m_wd <= {15'd0, present}; end
        endcase
        mi <= mi + 3'd1;
        if (mi == 3'd6) begin
            ms <= M_DONE;
        end
    end
    M_SEC: begin                         // m_addr 0: the sector number
        sd_lba <= {16'd0, m_rd};
        bi <= '0;
        sd_busy <= 1'b0;
        if (wr_op) begin                 // a whole sector: nothing to read first
            m_addr <= 4'hF;
            ms <= M_DRAIN;
        end
        else begin
            sd_rd <= 1'b1;
            ms <= M_RD;
        end
    end
    M_RD: begin
        if (sd_ack) begin
            sd_rd <= 1'b0;
            sd_busy <= 1'b1;
        end
        else if (sd_busy) begin
            sd_busy <= 1'b0;
            m_addr <= 4'hF;
            ms <= M_FILL;
        end
    end
    // a read: the sector's 512 bytes into floppy.v's FIFO, low byte first
    M_FILL: begin                        // b_ra set this clock, b_q next
        ms <= M_FILLW;
    end
    M_FILLW: begin
        m_write <= 1'b1;
        m_wd <= {8'd0, bi[0] ? b_q[15:8] : b_q[7:0]};
        bi <= bi + 10'd1;
        ms <= bi == 10'd511 ? M_DONE : M_FILL;
    end
    // a write: the FIFO's 512 bytes into the buffer; floppy.v's fifo_readdata follows a pop
    M_DRAIN: begin
        m_read <= 1'b1;
        ms <= M_DRAINW;
    end
    M_DRAINW: begin                      // m_rd: the byte popped last clock
        if (!bi[0]) begin
            lo <= m_rd[7:0];
        end
        bi <= bi + 10'd1;
        if (bi == 10'd511) begin
            sd_wr <= 1'b1;
            sd_busy <= 1'b0;
            ms <= M_WR;
        end
        else begin
            ms <= M_DRAIN;
        end
    end
    M_WR: begin
        if (sd_ack) begin
            sd_wr <= 1'b0;
            sd_busy <= 1'b1;
        end
        else if (sd_busy) begin          // request dropped with the FIFO empty; the next may be up
            sd_busy <= 1'b0;
            ms <= M_IDLE;
        end
    end
    M_DONE: begin                        // a fill: floppy.v drops request once its FIFO is full
        m_addr <= 4'd0;
        if (f_request == 2'b00 || mi == 3'd7) begin
            mi <= 3'd0;
            ms <= M_IDLE;
        end
    end
    default: ms <= M_IDLE;
    endcase
    // floppy.v reset mid-sector (a software reset): the FIFO side stops; an hps_io transfer in flight
    // finishes first (M_RD then stops at M_FILL or M_DRAIN)
    if (f_request == 2'b00 && (ms == M_FILL || ms == M_FILLW || ms == M_DRAIN || ms == M_DRAINW)) begin
        ms <= M_IDLE;
    end
    // the media survive the board's reset (floppy.v keeps them through rst_n); a sector op does not
    if (reset && ms != M_MEDIA && !(ms == M_IDLE && mnt)) begin
        ms <= M_IDLE;
        sd_rd <= 1'b0;
        sd_wr <= 1'b0;
        m_addr <= 4'd0;
    end
end

`ifdef DEBUG_ISSP
// [stp] probe L: a ring of the last 1,024 events, read by setting the source to an index. An entry
// is {type[31:28], time[27:16] (2^16 clocks a step), payload[15:0]}. Types: 1 an access other than
// an MSR read or a data-phase byte, payload {we, port, 4'h0, data (a read's: the CPU's)}; 2 a
// data-phase run ended, payload its bytes; 3 its first two bytes; 4 sd_wr up, payload sd_lba; 5
// sd_rd up, sd_lba; 6 sd_ack down, payload 1 after a write; 7 a mount. probe = {write index, entry}.
logic [15:0] l_div = '0;
logic [11:0] l_ts = '0;
logic [31:0] l_mem [1024];
logic [9:0]  l_wp = '0;
logic [9:0]  l_ra;
logic [31:0] l_q;
logic        l_rq = 1'b0;                // an access last clock: its read data is f_q now
logic        l_rwe;
logic [2:0]  l_rport;
logic [7:0]  l_rwd;
logic [7:0]  l_msr = '0;
logic        l_inrun = 1'b0;
logic [15:0] l_run, l_first;
logic        p_acc = 1'b0;               // the access that ended a run, logged after it
logic [31:0] l_accwd;
logic        p_first = 1'b0, p_wr = 1'b0, p_rd = 1'b0, p_ack = 1'b0, p_mnt = 1'b0;
logic        p_ackw;
logic        l_sdwr_q = 1'b0, l_sdrd_q = 1'b0, l_ack_q = 1'b0;
logic        l_we;
logic [31:0] l_wd;
wire  [9:0]  l_src;
always_comb begin
    l_we = 1'b0;
    l_wd = '0;
    if (l_rq && !(l_rport == 3'd4 && !l_rwe) && !(l_rport == 3'd5 && l_msr[5])) begin
        l_we = 1'b1;
        if (l_inrun) begin
            l_wd = {4'd2, l_ts, l_run};
        end
        else begin
            l_wd = {4'd1, l_ts, l_rwe, l_rport, 4'h0, l_rwe ? l_rwd : rdata};
        end
    end
    else if (p_first) begin
        l_we = 1'b1;
        l_wd = {4'd3, l_ts, l_first};
    end
    else if (p_acc) begin
        l_we = 1'b1;
        l_wd = l_accwd;
    end
    else if (p_wr) begin
        l_we = 1'b1;
        l_wd = {4'd4, l_ts, sd_lba[15:0]};
    end
    else if (p_rd) begin
        l_we = 1'b1;
        l_wd = {4'd5, l_ts, sd_lba[15:0]};
    end
    else if (p_ack) begin
        l_we = 1'b1;
        l_wd = {4'd6, l_ts, 15'd0, p_ackw};
    end
    else if (p_mnt) begin
        l_we = 1'b1;
        l_wd = {4'd7, l_ts, 16'd0};
    end
end
always_ff @(posedge clk) begin
    l_div <= l_div + 16'd1;
    if (&l_div) begin
        l_ts <= l_ts + 12'd1;
    end
    l_rq <= req;
    l_rwe <= we;
    l_rport <= port;
    l_rwd <= wdata;
    l_sdwr_q <= sd_wr;
    l_sdrd_q <= sd_rd;
    l_ack_q <= sd_ack;
    if (sd_wr && !l_sdwr_q) begin
        p_wr <= 1'b1;
    end
    if (sd_rd && !l_sdrd_q) begin
        p_rd <= 1'b1;
    end
    if (!sd_ack && l_ack_q) begin
        p_ack <= 1'b1;
        p_ackw <= ms == M_WR || ms == M_IDLE && wr_op;
    end
    if (img_mounted) begin
        p_mnt <= 1'b1;
    end
    if (l_rq && l_rport == 3'd4 && !l_rwe) begin
        l_msr <= rdata;
    end
    if (l_rq && l_rport == 3'd5 && l_msr[5]) begin   // a data-phase byte
        if (!l_inrun) begin
            l_run <= 16'd1;
            l_first <= {l_rwe ? l_rwd : rdata, 8'h00};
        end
        else begin
            if (l_run == 16'd1) begin
                l_first[7:0] <= l_rwe ? l_rwd : rdata;
            end
            if (l_run != 16'hFFFF) begin
                l_run <= l_run + 16'd1;
            end
        end
        l_inrun <= 1'b1;
    end
    if (l_we) begin
        l_mem[l_wp] <= l_wd;
        l_wp <= l_wp + 10'd1;
        if (l_rq && !(l_rport == 3'd4 && !l_rwe) && !(l_rport == 3'd5 && l_msr[5])) begin
            if (l_inrun) begin                    // the run's count now, its bytes and the access next
                l_inrun <= 1'b0;
                p_first <= 1'b1;
                p_acc <= 1'b1;
                l_accwd <= {4'd1, l_ts, l_rwe, l_rport, 4'h0, l_rwe ? l_rwd : rdata};
            end
        end
        else if (p_first) begin
            p_first <= 1'b0;
        end
        else if (p_acc) begin
            p_acc <= 1'b0;
        end
        else if (p_wr) begin
            p_wr <= 1'b0;
        end
        else if (p_rd) begin
            p_rd <= 1'b0;
        end
        else if (p_ack) begin
            p_ack <= 1'b0;
        end
        else if (p_mnt) begin
            p_mnt <= 1'b0;
        end
    end
    l_ra <= l_src;
    l_q <= l_mem[l_ra];
end
issp_probe #(.INSTANCE_ID("L"), .PROBE_W(42), .SOURCE_W(10)) u_probe_l (
    .clk,
    .probe({l_wp, l_q}),
    .source(l_src)
);
`endif

endmodule
