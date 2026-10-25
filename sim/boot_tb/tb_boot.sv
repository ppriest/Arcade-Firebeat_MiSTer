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
    output logic         v_req,
    output logic         v_we,
    output logic [22:0]  v_addr,
    output logic [31:0]  v_wdata,
    input  logic         v_ack,
    input  logic [31:0]  v_rdata,
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
    input  logic [31:0]  dbg_wdata
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
    fb_board u (.*);
endmodule
