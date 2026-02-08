// vsrc/test/tb_lsu.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_lsu (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Request interface
    input  logic req_valid_i,
    output logic req_ready_o,
    input  logic is_load_i,
    input  logic is_store_i,
    input  logic [3:0] lsu_op_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] imm_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] rs1_data_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] rs2_data_i,
    input  logic [5:0] rob_tag_i,
    input  logic [3:0] sb_id_i,

    // Store buffer execute write
    output logic                        sb_ex_valid_o,
    output logic [3:0]                  sb_ex_sb_id_o,
    output logic [global_config_pkg::Cfg.PLEN-1:0] sb_ex_addr_o,
    output logic [global_config_pkg::Cfg.XLEN-1:0] sb_ex_data_o,
    output decode_pkg::lsu_op_e         sb_ex_op_o,

    // Store-to-load forwarding
    output logic [global_config_pkg::Cfg.PLEN-1:0] sb_load_addr_o,
    input  logic                       sb_load_hit_i,
    input  logic                       sb_load_block_i,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] sb_load_data_i,

    // DCache load port
    output logic                       ld_req_valid_o,
    input  logic                       ld_req_ready_i,
    output logic [global_config_pkg::Cfg.PLEN-1:0] ld_req_addr_o,
    output decode_pkg::lsu_op_e        ld_req_op_o,

    input  logic                       ld_rsp_valid_i,
    output logic                       ld_rsp_ready_o,
    input  logic [global_config_pkg::Cfg.XLEN-1:0] ld_rsp_data_i,
    input  logic                       ld_rsp_err_i,

    // Writeback
    output logic                       wb_valid_o,
    output logic [5:0]                 wb_rob_idx_o,
    output logic [global_config_pkg::Cfg.XLEN-1:0] wb_data_o,
    output logic                       wb_exception_o,
    output logic [4:0]                 wb_ecause_o,
    output logic                       wb_is_mispred_o,
    output logic [global_config_pkg::Cfg.PLEN-1:0] wb_redirect_pc_o,
    input  logic                       wb_ready_i
);

  decode_pkg::uop_t uop;
  always_comb begin
    uop = '0;
    uop.valid    = 1'b1;
    uop.is_load  = is_load_i;
    uop.is_store = is_store_i;
    uop.lsu_op   = decode_pkg::lsu_op_e'(lsu_op_i);
    uop.imm      = imm_i;
  end

  lsu #(
      .Cfg(global_config_pkg::Cfg),
      .ROB_IDX_WIDTH(6),
      .SB_DEPTH(16)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,

      .req_valid_i,
      .req_ready_o,
      .uop_i(uop),
      .rs1_data_i,
      .rs2_data_i,
      .rob_tag_i,
      .sb_id_i,

      .sb_ex_valid_o,
      .sb_ex_sb_id_o,
      .sb_ex_addr_o,
      .sb_ex_data_o,
      .sb_ex_op_o,

      .sb_load_addr_o,
      .sb_load_hit_i,
      .sb_load_block_i,
      .sb_load_data_i,

      .ld_req_valid_o,
      .ld_req_ready_i,
      .ld_req_addr_o,
      .ld_req_op_o,

      .ld_rsp_valid_i,
      .ld_rsp_ready_o,
      .ld_rsp_data_i,
      .ld_rsp_err_i,

      .wb_valid_o,
      .wb_rob_idx_o,
      .wb_data_o,
      .wb_exception_o,
      .wb_ecause_o,
      .wb_is_mispred_o,
      .wb_redirect_pc_o,
      .wb_ready_i
  );

endmodule
