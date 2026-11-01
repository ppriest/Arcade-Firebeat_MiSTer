// SPDX-License-Identifier: GPL-3.0-or-later
// rtl/board/fb_board.sv for sim/boot_tb/main.cpp: the board from power-on.
module tb_boot (
    input  logic         clk,
    input  logic         reset,
    input  logic         ce,
    input  logic         dma_hold,
    input  logic         tb_en,
    input  logic [4:0]   irq_force,
    output logic         dma_busy,
    output logic         c_req,
    output logic         c_we,
    output logic [26:4]  c_addr,
    output logic [127:0] c_wdata,
    input  logic         c_ack,
    input  logic [127:0] c_rdata,
    output logic         m_req,
    output logic [26:5]  m_addr,
    input  logic         m_ack,
    input  logic [255:0] m_rdata,
    output logic         w_req,
    output logic         w_we,
    output logic [26:2]  w_addr,
    output logic [3:0]   w_be,
    output logic [31:0]  w_wdata,
    input  logic         w_ack,
    input  logic [31:0]  w_rdata,
    // VRAM: the DDRAM port of the GCU's hornet_ddr3 (sim/common/ddr3_model.h)
    input  logic         DDRAM_BUSY,
    output logic [7:0]   DDRAM_BURSTCNT,
    output logic [28:0]  DDRAM_ADDR,
    input  logic [63:0]  DDRAM_DOUT,
    input  logic         DDRAM_DOUT_READY,
    output logic         DDRAM_RD,
    output logic [63:0]  DDRAM_DIN,
    output logic [7:0]   DDRAM_BE,
    output logic         DDRAM_WE,
    input  logic [1:0]   img_mounted,
    input  logic [63:0]  img_size,
    output logic [31:0]  sd_lba0,
    output logic [31:0]  sd_lba1,
    output logic [5:0]   sd_blk_cnt0,
    output logic [5:0]   sd_blk_cnt1,
    output logic [1:0]   sd_rd,
    input  logic [1:0]   sd_ack,
    input  logic         sd_buff_wr,
    input  logic [15:0]  sd_buff_dout,
    input  logic         vblank,
    input  logic [7:0]   in0, in1, in2, in3,
    input  logic [63:0]  sensors,
    input  logic [3:0]   cabinet_info,
    output logic [7:0]   control,
    input  logic         dg_we,
    input  logic [7:0]   dg_addr,
    input  logic [7:0]   dg_data,
    input  logic         rtc_nv_we,
    input  logic [12:0]  rtc_nv_addr,
    input  logic [7:0]   rtc_nv_wdata,
    output logic [7:0]   rtc_nv_rdata,
    input  logic         por,            // power-on: the RTC's reset, which the board's leaves alone
    input  logic         rtc_set,
    input  logic [55:0]  rtc_time,
    output logic         gcu_cmd_v,
    output logic         gcu_cmd_port,
    output logic [127:0] gcu_cmd,
    output logic         mon_v,
    output logic         mon_we,
    output logic [30:0]  mon_addr,
    output logic [31:0]  mon_mask,
    output logic [31:0]  mon_data,
    output logic         bad,
    output logic         dbg_exec,
    output logic [31:0]  dbg_pc,
    output logic [31:0]  dbg_ir,
    input  logic [5:0]   dbg_sel,
    output logic [31:0]  dbg_val,
    input  logic         dbg_we,
    input  logic [5:0]   dbg_wsel,
    input  logic [31:0]  dbg_wdata,
    // the state dump (rtl/board/fb_dump.sv) on hornet_ddr3 master 1
    input  logic         dump_start,
    output logic         dump_busy,
    output logic         dump_held,
    // the state load (+state): a register-block word written while ld_we
    input  logic         ld_we,
    input  logic [13:0]  ld_a,
    input  logic [31:0]  ld_d
);
    logic [15:0] sensor [4];
    assign sensor[0] = sensors[15:0];
    assign sensor[1] = sensors[31:16];
    assign sensor[2] = sensors[47:32];
    assign sensor[3] = sensors[63:48];
    logic [31:0] sd_lba [2];
    logic [5:0]  sd_blk_cnt [2];
    assign sd_lba0 = sd_lba[0];
    assign sd_lba1 = sd_lba[1];
    assign sd_blk_cnt0 = sd_blk_cnt[0];
    assign sd_blk_cnt1 = sd_blk_cnt[1];
    logic        vm_read, vm_write, vm_waitn, vm_rvalid;
    logic [31:0] vm_addr, vm_wdata, vm_wdata_hi, vm_rdata, vm_rdata_hi;
    logic [10:0] vm_burst;
    logic [3:0]  vm_be, vm_be_hi;
    logic         b_c_req, b_c_we, x_halt, x_frozen, x_own, x_c_req;
    logic [26:4]  b_c_addr, x_c_addr;
    logic [13:0]  st_a;
    logic [31:0]  st_d;
    logic         x_write;
    logic [31:0]  x_addr, x_wdata, x_wdata_hi;
    logic [10:0]  x_burst;
    fb_board u (.*, .halt(x_halt), .frozen(x_frozen), .st_a(ld_we ? ld_a : st_a), .st_d,
        .st_we(ld_we), .st_wd(ld_d), .ata_check(), .ata_key(), .aud_l(), .aud_r(), .nv_wr(),
        .c_req(b_c_req), .c_we(b_c_we), .c_addr(b_c_addr), .c_ack(c_ack && !x_own), .gd_crtc(), .gd_layer(), .gd_alpha(), .gd_x(), .gd_y(), .gd_w(), .gd_h(), .gd_base(), .gd_6c());
    assign c_req  = x_own ? x_c_req : b_c_req;
    assign c_we   = !x_own && b_c_we;
    assign c_addr = x_own ? x_c_addr : b_c_addr;
    fb_dump u_dump (
        .clk, .reset(por), .abort(reset), .start(dump_start), .halt(x_halt), .frozen(x_frozen),
        .port_free(!b_c_req && sd_rd == 2'b00), .busy(dump_busy), .own(x_own), .st_a, .st_d,
        .c_req(x_c_req), .c_addr(x_c_addr), .c_ack(c_ack && x_own), .c_rdata,
        .m_write(x_write), .m_addr(x_addr), .m_burst(x_burst), .m_wdata(x_wdata),
        .m_wdata_hi(x_wdata_hi), .m_waitn(d_waitn[1])
    );
    assign dump_held = x_halt && !dump_busy;
    logic [1:0] d_waitn, d_rvalid;
    hornet_ddr3 #(.N(2), .WIDE(2'b11), .PRI(0)) u_ddr3 (
        .clk, .reset(por), .drain(1'b0), .idle(),
        .m_read({1'b0, vm_read}), .m_write({x_write, vm_write}), .m_addr({x_addr, vm_addr}),
        .m_burst({x_burst, vm_burst}), .m_be({4'hF, vm_be}), .m_wdata({x_wdata, vm_wdata}),
        .m_be_hi({4'hF, vm_be_hi}), .m_wdata_hi({x_wdata_hi, vm_wdata_hi}), .m_waitn(d_waitn),
        .m_rvalid(d_rvalid), .m_rready(2'b11), .m_rdata(vm_rdata), .m_rdata_hi(vm_rdata_hi),
        .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
        .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .dbg(), .dbg_cmd()
    );
    assign vm_waitn = d_waitn[0];
    assign vm_rvalid = d_rvalid[0];
endmodule
