// vsrc/test/tb_execute.sv
import config_pkg::*;
import decode_pkg::*;

module tb_execute (
    input  logic        clk_i,
    input  logic        rst_ni,

    // 简单信号输入
    input  logic [31:0] pc_i,
    input  logic [31:0] imm_i,
    input  logic [4:0]  alu_op_i,
    input  logic [2:0]  br_op_i,
    input  logic        is_branch_i,
    input  logic        is_jump_i,
    input  logic [31:0] rs1_data_i,
    input  logic [31:0] rs2_data_i,
    input  logic [5:0]  rob_tag_in,
    input  logic        has_rs2_i,

    // 输出结果
    output logic [31:0] alu_result_o,
    output logic [5:0]  rob_tag_out,
    output logic        is_mispred_o,
    output logic [31:0] redirect_pc_o
);

    decode_pkg::uop_t uop;
    
    // 构造 uop 结构体
    always_comb begin
        uop = '0;
        uop.pc        = pc_i;
        uop.imm       = imm_i;
        uop.alu_op    = decode_pkg::alu_op_e'(alu_op_i);
        uop.br_op     = decode_pkg::branch_op_e'(br_op_i);
        uop.is_branch = is_branch_i;
        uop.is_jump   = is_jump_i;
        uop.valid     = 1'b1;
        uop.has_rs2   = has_rs2_i;
    end

    execute_alu #(
        .Cfg(config_pkg::EmptyCfg),
        .TAG_W(6)
    ) dut (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .alu_valid_i       (1'b1),
        .uop_i             (uop),
        .rs1_data_i        (rs1_data_i),
        .rs2_data_i        (rs2_data_i),
        .rob_tag_i         (rob_tag_in),
        
        .alu_valid_o       (),
        .alu_rob_tag_o     (rob_tag_out),
        .alu_result_o      (alu_result_o),
        .alu_is_mispred_o  (is_mispred_o),
        .alu_redirect_pc_o (redirect_pc_o)
    );

endmodule