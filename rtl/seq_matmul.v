`timescale 1ns/1ps

// SysMAC: Systolic Array Matrix Multiplication Accelerator
// Module: seq_matmul
// Author: Priyanshu Tomar
//
// Sequential baseline: C = A x B with ONE multiply-accumulate unit, the way
// a CPU triple loop does it. Same ports and same handshake as
// systolic_accelerator_top, so the same testbench and vectors drive both.
//
// FSM: IDLE -> LOAD (1) -> COMPUTE (27, one MAC per cycle) -> DONE (1) -> IDLE
//
//   for i, for j, for k:  acc = (k == 0 ? 0 : acc) + A[i][k] * B[k][j]
//   when k == 2, C[i][j] <= acc
//
// a_flat/b_flat must be stable while start is sampled and through LOAD.
// c_flat is valid while done = 1 (it is rewritten during the next job).
module seq_matmul (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [71:0]  a_flat,
    input  wire [71:0]  b_flat,
    output wire         done,
    output wire [287:0] c_flat
);
    localparam IDLE = 2'd0, LOAD = 2'd1, COMPUTE = 2'd2, DONE = 2'd3;

    reg [1:0]          state;
    reg [71:0]         a_mat, b_mat;
    reg [1:0]          i, j, k;
    reg signed [31:0]  acc;
    reg [287:0]        c_reg;

    // Operands for this cycle, picked from the latched matrices.
    wire signed [7:0]  a_op = a_mat[(i*3 + k)*8 +: 8];
    wire signed [7:0]  b_op = b_mat[(k*3 + j)*8 +: 8];
    wire signed [15:0] product = a_op * b_op;
    wire signed [31:0] acc_in  = (k == 2'd0) ? 32'sd0 : acc;
    wire signed [31:0] mac     = acc_in + product;

    assign done   = (state == DONE);
    assign c_flat = c_reg;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            a_mat <= 72'd0;
            b_mat <= 72'd0;
            i <= 2'd0; j <= 2'd0; k <= 2'd0;
            acc   <= 32'sd0;
            c_reg <= 288'd0;
        end else begin
            case (state)
                IDLE: if (start) state <= LOAD;
                LOAD: begin
                    a_mat <= a_flat;
                    b_mat <= b_flat;
                    i <= 2'd0; j <= 2'd0; k <= 2'd0;
                    state <= COMPUTE;
                end
                COMPUTE: begin
                    acc <= mac;
                    if (k == 2'd2) begin
                        c_reg[(i*3 + j)*32 +: 32] <= mac;
                        k <= 2'd0;
                        if (j == 2'd2) begin
                            j <= 2'd0;
                            if (i == 2'd2) state <= DONE;
                            else           i <= i + 2'd1;
                        end else begin
                            j <= j + 2'd1;
                        end
                    end else begin
                        k <= k + 2'd1;
                    end
                end
                DONE:    state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
