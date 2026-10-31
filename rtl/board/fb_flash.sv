// SPDX-License-Identifier: GPL-3.0-or-later
//
// The three Fujitsu MBM29F016A (2 MB, 8-bit) as MAME runs them (devices/machine/intelfsh.cpp,
// maker 0x04, device 0xAD): flash_main at 0x7D400000, flash_snd1 at 0x7D800000, flash_snd2 at
// 0x7DA00000 (firebeat.cpp:791-793). The data is in SDRAM at 0x2000000 + chip x 0x200000
// (firebeat_sys), through firebeat_sdram's word port.
//
// Commands, MAME's write_full for this part: F0/FF reset; 90 read ID (maker at offset 0, device at
// 1, 0 at 2); 50 clear status (status 0x80); 70 read status; 40/10 program one byte (then status);
// the AMD sequence AA at x555/xAAA, 55 at x2AA/x2AAA/x555, then 90 (ID), A0 (program the next
// byte), F0 (reset), 20 (fast mode: A0 programs directly, 90 then F0/00 leaves it) or 80 AA 55
// followed by 10 (erase the chip) or 30 (erase the 64 KB sector of the address). An erase sets
// status 0x08; until MAME's timer ends (16 s chip, 1 s sector) every read returns the status with
// bits 6 and 2 toggled at each read (MAME reads status anywhere for this part: firebeat.cpp's
// pop'n music note in intelfsh.cpp); then normal mode, status 0x80. The erased bytes become 0xFF
// in SDRAM in the background. Intel block erase (20 D0) and the master lock (60) set `bad`.
//
// Port c: the CPU's byte accesses (offset within the chip). Port y: the YMZ280B's reads of the two
// sound chips (its 4 MB space: snd1 then snd2), through the same mode logic, as MAME's ymz280b_map.

module fb_flash (
    input  logic        clk,
    input  logic        reset,

    input  logic        c_req,          // held until c_ack
    input  logic        c_we,
    input  logic [1:0]  c_chip,         // 0 main, 1 snd1, 2 snd2
    input  logic [20:0] c_addr,
    input  logic [7:0]  c_wdata,
    output logic        c_ack,
    output logic [7:0]  c_rdata,

    input  logic        y_req,          // held until y_ack
    input  logic [21:0] y_addr,
    output logic        y_ack,
    output logic [7:0]  y_rdata,

    output logic        w_req,
    output logic        w_we,
    output logic [26:2] w_addr,
    output logic [3:0]  w_be,
    output logic [31:0] w_wdata,
    input  logic        w_ack,
    input  logic [31:0] w_rdata,

    output logic        bad,
    input  logic [5:0]  st_a,           // [Firebeat] the state dump's register block (end of file)
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd
);

localparam logic [31:0] T_SECTOR = 32'd66_666_667;      // 1 s
localparam logic [31:0] T_CHIP   = 32'd1_066_666_667;   // 16 s

typedef enum logic [3:0] {
    F_NORMAL, F_READID, F_READSTATUS, F_WRITEPART1, F_AMD1, F_AMD2, F_AMD3ID, F_ERASE1, F_ERASE2,
    F_ERASE3, F_ERASE4, F_BYTEPROG, F_FASTRESET
} fm_t;

fm_t        mode [3];
logic [7:0] status [3];
logic       fast [3];
logic [31:0] tmr [3];

// the background erase: 0xFF words over [e_a, e_end) of one chip's SDRAM
logic        e_on;
logic [26:2] e_a, e_end;

// an SDRAM access in hand
typedef enum logic [1:0] { A_NONE, A_CPU, A_YMZ, A_ERASE } a_t;
a_t          a_who;
logic        a_busy;
logic [26:0] a_byte;                    // SDRAM byte address
logic        a_we;
logic [7:0]  a_wd;

function automatic logic [26:0] sd(input logic [1:0] chip, input logic [20:0] a);
    return 27'h2000000 + {chip, 21'd0} + {6'd0, a};
endfunction
function automatic logic [7:0] lane(input logic [31:0] w, input logic [1:0] b);
    return w[31 - 8*b -: 8];            // big-endian: byte 0 in bits 31:24
endfunction

assign w_req   = a_busy;
assign w_we    = a_we;
assign w_addr  = a_byte[26:2];
assign w_be    = (a_who == A_ERASE || !a_we) ? 4'hF : (4'b1000 >> a_byte[1:0]);
assign w_wdata = (a_who == A_ERASE) ? 32'hFFFF_FFFF : {4{a_wd}};

// port c, decided in the clock it is seen; port y likewise. One at a time, c first.
logic c_pend, y_pend;
wire  [1:0] yc = y_addr[21] ? 2'd2 : 2'd1;

always_ff @(posedge clk) begin
    c_ack <= 1'b0;
    y_ack <= 1'b0;

    for (int k = 0; k < 3; k++)
        if (tmr[k] != 32'd0) begin
            tmr[k] <= tmr[k] - 32'd1;
            if (tmr[k] == 32'd1 && mode[k] == F_ERASE4) begin mode[k] <= F_NORMAL; status[k] <= 8'h80; end
        end

    if (a_busy && w_ack) begin
        a_busy <= 1'b0;
        case (a_who)
        A_CPU: begin c_ack <= 1'b1; c_rdata <= lane(w_rdata, a_byte[1:0]); c_pend <= 1'b0; end
        A_YMZ: begin y_ack <= 1'b1; y_rdata <= lane(w_rdata, a_byte[1:0]); y_pend <= 1'b0; end
        A_ERASE: begin e_a <= e_a + 25'd1; if (e_a + 25'd1 == e_end) e_on <= 1'b0; end
        default: ;
        endcase
    end

    // a request is taken when no SDRAM access is in hand (the erase's are a word each)
    if (c_req && !c_pend && !c_ack && !a_busy) begin
        logic [1:0] k;
        logic [7:0] d;
        logic [11:0] a12;
        logic [15:0] a16;
        k = c_chip; d = c_wdata; a12 = c_addr[11:0]; a16 = c_addr[15:0];
        c_pend <= 1'b1;
        if (!c_we) begin
            case (mode[k])
            F_NORMAL, F_AMD1, F_AMD2, F_ERASE1, F_ERASE2, F_ERASE3, F_BYTEPROG, F_FASTRESET, F_WRITEPART1: begin
                a_busy <= 1'b1; a_who <= A_CPU; a_we <= 1'b0; a_byte <= sd(k, c_addr);
            end
            F_READSTATUS: begin c_rdata <= status[k]; c_ack <= 1'b1; c_pend <= 1'b0; end
            F_READID, F_AMD3ID: begin
                c_rdata <= (c_addr[7:0] == 8'd0) ? 8'h04 : (c_addr[7:0] == 8'd1) ? 8'hAD : 8'h00;
                c_ack <= 1'b1; c_pend <= 1'b0;
            end
            F_ERASE4: begin
                c_rdata <= status[k] ^ 8'h44; status[k] <= status[k] ^ 8'h44;
                c_ack <= 1'b1; c_pend <= 1'b0;
            end
            default: begin c_rdata <= 8'hFF; c_ack <= 1'b1; c_pend <= 1'b0; end
            endcase
        end else begin
            c_ack <= 1'b1; c_pend <= 1'b0;     // a write is answered at once unless it programs
            case (mode[k])
            F_NORMAL, F_READSTATUS, F_READID, F_AMD3ID:
                case (d)
                8'hF0, 8'hFF: mode[k] <= F_NORMAL;
                8'h90: mode[k] <= fast[k] ? F_FASTRESET : F_READID;
                8'h40, 8'h10: mode[k] <= F_WRITEPART1;
                8'h50: begin status[k] <= 8'h80; mode[k] <= F_READSTATUS; end
                8'h20, 8'h60: bad <= 1'b1;
                8'h70: mode[k] <= F_READSTATUS;
                8'hA0: if (fast[k]) mode[k] <= F_BYTEPROG;
                8'hAA: if (a12 == 12'h555 || a12 == 12'hAAA) mode[k] <= F_AMD1;
                default: ;
                endcase
            F_AMD1:
                mode[k] <= (d == 8'h55 && (a16 == 16'h02AA || a16 == 16'h2AAA || a12 == 12'h555)) ? F_AMD2 : F_NORMAL;
            F_AMD2:
                if (a16 == 16'h0555 || a16 == 16'h5555 || a12 == 12'hAAA)
                    case (d)
                    8'h90: mode[k] <= F_AMD3ID;
                    8'h80: mode[k] <= F_ERASE1;
                    8'hA0: mode[k] <= F_BYTEPROG;
                    8'hF0: mode[k] <= F_NORMAL;
                    8'h20: begin mode[k] <= F_NORMAL; fast[k] <= 1'b1; end
                    default: mode[k] <= F_NORMAL;
                    endcase
                else if ((a12 == 12'hAAA || a12 == 12'h555) && d == 8'h20) begin mode[k] <= F_NORMAL; fast[k] <= 1'b1; end
                else mode[k] <= F_NORMAL;
            F_ERASE1: if ((a12 == 12'h555 || a12 == 12'hAAA) && d == 8'hAA) mode[k] <= F_ERASE2;
            F_ERASE2: if ((a16 == 16'h02AA || a16 == 16'h2AAA || a12 == 12'h555) && d == 8'h55) mode[k] <= F_ERASE3;
            F_ERASE3:
                if ((a12 == 12'h555 || a12 == 12'hAAA) && d == 8'h10) begin
                    status[k] <= 8'h08; mode[k] <= F_ERASE4; tmr[k] <= T_CHIP;
                    e_on <= 1'b1; e_a <= sd(k, 21'd0) >> 2; e_end <= (sd(k, 21'd0) + 27'h200000) >> 2;
                end else if (d == 8'h30) begin
                    status[k] <= 8'h08; mode[k] <= F_ERASE4; tmr[k] <= T_SECTOR;
                    e_on <= 1'b1; e_a <= sd(k, {c_addr[20:16], 16'd0}) >> 2;
                    e_end <= (sd(k, {c_addr[20:16], 16'd0}) + 27'h10000) >> 2;
                end
            F_BYTEPROG, F_WRITEPART1: begin
                c_ack <= 1'b0; c_pend <= 1'b1;
                a_busy <= 1'b1; a_who <= A_CPU; a_we <= 1'b1; a_wd <= d; a_byte <= sd(k, c_addr);
                if (mode[k] == F_WRITEPART1) begin status[k] <= 8'h80; mode[k] <= F_READSTATUS; end
                else mode[k] <= F_NORMAL;
            end
            F_FASTRESET: if (d == 8'hF0 || d == 8'h00) begin fast[k] <= 1'b0; mode[k] <= F_NORMAL; end
            default: ;
            endcase
        end
    end else if (y_req && !y_pend && !y_ack && !a_busy && !(c_req && !c_pend)) begin
        y_pend <= 1'b1;
        if (mode[yc] == F_ERASE4) begin
            y_rdata <= status[yc] ^ 8'h44; status[yc] <= status[yc] ^ 8'h44; y_ack <= 1'b1; y_pend <= 1'b0;
        end else if (mode[yc] == F_READSTATUS) begin y_rdata <= status[yc]; y_ack <= 1'b1; y_pend <= 1'b0; end
        else if (mode[yc] == F_READID || mode[yc] == F_AMD3ID) begin
            y_rdata <= (y_addr[7:0] == 8'd0) ? 8'h04 : (y_addr[7:0] == 8'd1) ? 8'hAD : 8'h00;
            y_ack <= 1'b1; y_pend <= 1'b0;
        end else begin
            a_busy <= 1'b1; a_who <= A_YMZ; a_we <= 1'b0; a_byte <= sd(yc, y_addr[20:0]);
        end
    end else if (e_on && !a_busy && !c_pend && !y_pend) begin
        a_busy <= 1'b1; a_who <= A_ERASE; a_we <= 1'b1; a_byte <= {e_a, 2'b00};
    end

    if (reset) begin
        for (int k = 0; k < 3; k++) begin mode[k] <= F_NORMAL; status[k] <= 8'h80; fast[k] <= 1'b0; tmr[k] <= '0; end
        e_on <= 1'b0; a_busy <= 1'b0; c_pend <= 1'b0; y_pend <= 1'b0; bad <= 1'b0;
    end
`ifdef VERILATOR  // st_lists: write
    if (st_we) case (st_a)
    6'h0: c_ack <= ($bits(c_ack))'(st_wd);
    6'h1: y_ack <= ($bits(y_ack))'(st_wd);
    6'h2: tmr[0] <= ($bits(tmr[0]))'(st_wd);
    6'h3: tmr[1] <= ($bits(tmr[1]))'(st_wd);
    6'h4: tmr[2] <= ($bits(tmr[2]))'(st_wd);
    6'h5: mode[0] <= fm_t'(st_wd[3:0]);
    6'h6: mode[1] <= fm_t'(st_wd[3:0]);
    6'h7: mode[2] <= fm_t'(st_wd[3:0]);
    6'h8: status[0] <= ($bits(status[0]))'(st_wd);
    6'h9: status[1] <= ($bits(status[1]))'(st_wd);
    6'hA: status[2] <= ($bits(status[2]))'(st_wd);
    6'hB: a_busy <= ($bits(a_busy))'(st_wd);
    6'hC: c_rdata <= ($bits(c_rdata))'(st_wd);
    6'hD: c_pend <= ($bits(c_pend))'(st_wd);
    6'hE: y_rdata <= ($bits(y_rdata))'(st_wd);
    6'hF: y_pend <= ($bits(y_pend))'(st_wd);
    6'h10: e_a <= ($bits(e_a))'(st_wd);
    6'h11: e_on <= ($bits(e_on))'(st_wd);
    6'h12: a_who <= a_t'(st_wd[3:0]);
    6'h13: a_we <= ($bits(a_we))'(st_wd);
    6'h14: a_byte <= ($bits(a_byte))'(st_wd);
    6'h15: bad <= ($bits(bad))'(st_wd);
    6'h16: fast[0] <= ($bits(fast[0]))'(st_wd);
    6'h17: fast[1] <= ($bits(fast[1]))'(st_wd);
    6'h18: fast[2] <= ($bits(fast[2]))'(st_wd);
    6'h19: e_end <= ($bits(e_end))'(st_wd);
    6'h1A: a_wd <= ($bits(a_wd))'(st_wd);
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
    6'h0: st_d = 32'(c_ack);
    6'h1: st_d = 32'(y_ack);
    6'h2: st_d = 32'(tmr[0]);
    6'h3: st_d = 32'(tmr[1]);
    6'h4: st_d = 32'(tmr[2]);
    6'h5: st_d = 32'(mode[0]);
    6'h6: st_d = 32'(mode[1]);
    6'h7: st_d = 32'(mode[2]);
    6'h8: st_d = 32'(status[0]);
    6'h9: st_d = 32'(status[1]);
    6'hA: st_d = 32'(status[2]);
    6'hB: st_d = 32'(a_busy);
    6'hC: st_d = 32'(c_rdata);
    6'hD: st_d = 32'(c_pend);
    6'hE: st_d = 32'(y_rdata);
    6'hF: st_d = 32'(y_pend);
    6'h10: st_d = 32'(e_a);
    6'h11: st_d = 32'(e_on);
    6'h12: st_d = 32'(a_who);
    6'h13: st_d = 32'(a_we);
    6'h14: st_d = 32'(a_byte);
    6'h15: st_d = 32'(bad);
    6'h16: st_d = 32'(fast[0]);
    6'h17: st_d = 32'(fast[1]);
    6'h18: st_d = 32'(fast[2]);
    6'h19: st_d = 32'(e_end);
    6'h1A: st_d = 32'(a_wd);
    default: ;
    endcase
end
// st_lists: end

endmodule
