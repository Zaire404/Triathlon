// vsrc/test/tb_triathlon.sv
import config_pkg::*;
import decode_pkg::*;
import global_config_pkg::*;

module tb_triathlon #(
    parameter int unsigned ROB_DEPTH = 64,
    parameter int unsigned ROB_IDX_W = $clog2(ROB_DEPTH),
    parameter int unsigned SB_DEPTH  = 16,
    parameter int unsigned SB_IDX_W  = $clog2(SB_DEPTH)
) (
    input logic clk_i,
    input logic rst_ni,

    // I-Cache miss/refill interface
    output logic                                  icache_miss_req_valid_o,
    input  logic                                  icache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] icache_miss_req_paddr_o,
    output logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_miss_req_victim_way_o,
    output logic [    Cfg.ICACHE_INDEX_WIDTH-1:0] icache_miss_req_index_o,

    input  logic                                  icache_refill_valid_i,
    output logic                                  icache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] icache_refill_paddr_i,
    input  logic [Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] icache_refill_way_i,
    input  logic [     Cfg.ICACHE_LINE_WIDTH-1:0] icache_refill_data_i,

    // D-Cache miss/refill/writeback interface
    output logic                                  dcache_miss_req_valid_o,
    input  logic                                  dcache_miss_req_ready_i,
    output logic [                  Cfg.PLEN-1:0] dcache_miss_req_paddr_o,
    output logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_miss_req_victim_way_o,
    output logic [    Cfg.DCACHE_INDEX_WIDTH-1:0] dcache_miss_req_index_o,

    input  logic                                  dcache_refill_valid_i,
    output logic                                  dcache_refill_ready_o,
    input  logic [                  Cfg.PLEN-1:0] dcache_refill_paddr_i,
    input  logic [Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] dcache_refill_way_i,
    input  logic [     Cfg.DCACHE_LINE_WIDTH-1:0] dcache_refill_data_i,

    output logic                             dcache_wb_req_valid_o,
    input  logic                             dcache_wb_req_ready_i,
    output logic [             Cfg.PLEN-1:0] dcache_wb_req_paddr_o,
    output logic [Cfg.DCACHE_LINE_WIDTH-1:0] dcache_wb_req_data_o,

    // Expose commit signals for test
    output logic [Cfg.NRET-1:0]                commit_valid_o,
    output logic [Cfg.NRET-1:0]                commit_we_o,
    output logic [Cfg.NRET-1:0][4:0]           commit_areg_o,
    output logic [Cfg.NRET-1:0][Cfg.XLEN-1:0]  commit_wdata_o,
    output logic [Cfg.NRET-1:0][Cfg.PLEN-1:0]  commit_pc_o,
    output logic                               backend_flush_o,
    output logic [Cfg.PLEN-1:0]                backend_redirect_pc_o,

    // Debug (frontend/backend handshakes)
    output logic                               dbg_fe_valid_o,
    output logic                               dbg_fe_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_fe_pc_o,
    output logic [Cfg.INSTR_PER_FETCH-1:0][Cfg.ILEN-1:0] dbg_fe_instrs_o,
    output logic                               dbg_dec_valid_o,
    output logic                               dbg_dec_ready_o,
    output logic                               dbg_rob_ready_o,

    // Debug (LSU load path)
    output logic                               dbg_lsu_ld_req_valid_o,
    output logic                               dbg_lsu_ld_req_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_lsu_ld_req_addr_o,
    output logic                               dbg_lsu_ld_rsp_valid_o,
    output logic                               dbg_lsu_ld_rsp_ready_o,
    output logic                               dbg_lsu_issue_valid_o,
    output logic                               dbg_lsu_req_ready_o,
    output logic                               dbg_lsu_issue_ready_o,
    output logic [4:0]                         dbg_lsu_free_count_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_busy_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_ready_o,
    output logic [Cfg.RS_DEPTH-1:0]            dbg_lsu_rs_head_match_o,
    output logic                               dbg_lsu_rs_head_valid_o,
    output logic [$clog2(Cfg.RS_DEPTH)-1:0]    dbg_lsu_rs_head_idx_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_dst_o,
    output logic                               dbg_lsu_rs_head_r1_ready_o,
    output logic                               dbg_lsu_rs_head_r2_ready_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_q1_o,
    output logic [ROB_IDX_W-1:0]               dbg_lsu_rs_head_q2_o,
    output logic                               dbg_lsu_rs_head_has_rs1_o,
    output logic                               dbg_lsu_rs_head_has_rs2_o,
    output logic                               dbg_lsu_rs_head_is_store_o,
    output logic                               dbg_lsu_rs_head_is_load_o,
    output logic [SB_IDX_W-1:0]                dbg_lsu_rs_head_sb_id_o,

    // Debug (Store buffer / D$ store path)
    output logic [3:0]                         dbg_sb_alloc_req_o,
    output logic                               dbg_sb_alloc_ready_o,
    output logic                               dbg_sb_alloc_fire_o,
    output logic                               dbg_sb_dcache_req_valid_o,
    output logic                               dbg_sb_dcache_req_ready_o,
    output logic [Cfg.PLEN-1:0]                dbg_sb_dcache_req_addr_o,
    output logic [Cfg.XLEN-1:0]                dbg_sb_dcache_req_data_o,

    // Debug (ROB head / count)
    output logic [$bits(decode_pkg::fu_e)-1:0] dbg_rob_head_fu_o,
    output logic                               dbg_rob_head_complete_o,
    output logic                               dbg_rob_head_is_store_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_head_pc_o,
    output logic [6:0]                         dbg_rob_count_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_head_ptr_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_tail_ptr_o,
    output logic                               dbg_rob_q2_valid_o,
    output logic [ROB_IDX_W-1:0]               dbg_rob_q2_idx_o,
    output logic [$bits(decode_pkg::fu_e)-1:0] dbg_rob_q2_fu_o,
    output logic                               dbg_rob_q2_complete_o,
    output logic                               dbg_rob_q2_is_store_o,
    output logic [Cfg.PLEN-1:0]                dbg_rob_q2_pc_o,

    // Debug (Store Buffer head / count)
    output logic [4:0]                         dbg_sb_count_o,
    output logic [3:0]                         dbg_sb_head_ptr_o,
    output logic [3:0]                         dbg_sb_tail_ptr_o,
    output logic                               dbg_sb_head_valid_o,
    output logic                               dbg_sb_head_committed_o,
    output logic                               dbg_sb_head_addr_valid_o,
    output logic                               dbg_sb_head_data_valid_o,
    output logic [Cfg.PLEN-1:0]                dbg_sb_head_addr_o,
    // Debug (BRU mispred info)
    output logic                               dbg_bru_mispred_o,
    output logic [Cfg.PLEN-1:0]                dbg_bru_pc_o,
    output logic [Cfg.XLEN-1:0]                dbg_bru_imm_o,
    output logic [$bits(decode_pkg::branch_op_e)-1:0] dbg_bru_op_o,
    output logic                               dbg_bru_is_jump_o,
    output logic                               dbg_bru_is_branch_o,
    output logic                               dbg_bru_valid_o,

    // Perf counters
    output logic [63:0]                        perf_cycles_o,
    output logic [63:0]                        perf_commit_cycles_o,
    output logic [63:0]                        perf_commit_instrs_o,
    output logic [63:0]                        perf_nocommit_cycles_o,
    output logic [63:0]                        perf_fe_empty_cycles_o,
    output logic [63:0]                        perf_fe_stall_cycles_o,
    output logic [63:0]                        perf_dec_stall_cycles_o,
    output logic [63:0]                        perf_rob_full_cycles_o,
    output logic [63:0]                        perf_issue_full_cycles_o,
    output logic [63:0]                        perf_alu_full_cycles_o,
    output logic [63:0]                        perf_bru_full_cycles_o,
    output logic [63:0]                        perf_lsu_full_cycles_o,
    output logic [63:0]                        perf_csr_full_cycles_o,
    output logic [63:0]                        perf_sb_full_cycles_o,
    output logic [63:0]                        perf_icache_miss_cycles_o,
    output logic [63:0]                        perf_dcache_miss_cycles_o,
    output logic [63:0]                        perf_flush_cycles_o,
    output logic [63:0]                        perf_icache_miss_reqs_o,
    output logic [63:0]                        perf_dcache_miss_reqs_o,
    output logic [63:0]                        perf_ifu_start_cycles_o,
    output logic [63:0]                        perf_ifu_wait_icache_cycles_o,
    output logic [63:0]                        perf_ifu_wait_ibuf_cycles_o,
    output logic [63:0]                        perf_icache_idle_cycles_o,
    output logic [63:0]                        perf_icache_lookup_cycles_o,
    output logic [63:0]                        perf_icache_miss_req_cycles_o,
    output logic [63:0]                        perf_icache_wait_refill_cycles_o,
    output logic [63:0]                        perf_lsu_idle_cycles_o,
    output logic [63:0]                        perf_lsu_ld_req_cycles_o,
    output logic [63:0]                        perf_lsu_ld_rsp_cycles_o,
    output logic [63:0]                        perf_lsu_resp_cycles_o,
    output logic [63:0]                        perf_dcache_idle_cycles_o,
    output logic [63:0]                        perf_dcache_lookup_cycles_o,
    output logic [63:0]                        perf_dcache_store_write_cycles_o,
    output logic [63:0]                        perf_dcache_wb_req_cycles_o,
    output logic [63:0]                        perf_dcache_miss_req_cycles_o,
    output logic [63:0]                        perf_dcache_wait_refill_cycles_o,
    output logic [63:0]                        perf_dcache_resp_cycles_o
);

  // localparams provided via module parameters
  localparam logic [1:0] IFU_S_START = 2'd0;
  localparam logic [1:0] IFU_S_WAIT_ICACHE = 2'd1;
  localparam logic [1:0] IFU_S_WAIT_IBUFFER = 2'd2;

  localparam logic [1:0] ICACHE_S_IDLE = 2'd0;
  localparam logic [1:0] ICACHE_S_LOOKUP = 2'd1;
  localparam logic [1:0] ICACHE_S_MISS_REQ = 2'd2;
  localparam logic [1:0] ICACHE_S_MISS_WAIT = 2'd3;

  localparam logic [1:0] LSU_S_IDLE = 2'd0;
  localparam logic [1:0] LSU_S_LD_REQ = 2'd1;
  localparam logic [1:0] LSU_S_LD_RSP = 2'd2;
  localparam logic [1:0] LSU_S_RESP = 2'd3;

  localparam logic [2:0] DCACHE_S_IDLE = 3'd0;
  localparam logic [2:0] DCACHE_S_LOOKUP = 3'd1;
  localparam logic [2:0] DCACHE_S_STORE_WRITE = 3'd2;
  localparam logic [2:0] DCACHE_S_WB_REQ = 3'd3;
  localparam logic [2:0] DCACHE_S_MISS_REQ = 3'd4;
  localparam logic [2:0] DCACHE_S_WAIT_REFILL = 3'd5;
  localparam logic [2:0] DCACHE_S_RESP = 3'd6;

  triathlon #(
      .Cfg(global_config_pkg::Cfg)
  ) dut (
      .clk_i,
      .rst_ni,

      .icache_miss_req_valid_o,
      .icache_miss_req_ready_i,
      .icache_miss_req_paddr_o,
      .icache_miss_req_victim_way_o,
      .icache_miss_req_index_o,

      .icache_refill_valid_i,
      .icache_refill_ready_o,
      .icache_refill_paddr_i,
      .icache_refill_way_i,
      .icache_refill_data_i,

      .dcache_miss_req_valid_o,
      .dcache_miss_req_ready_i,
      .dcache_miss_req_paddr_o,
      .dcache_miss_req_victim_way_o,
      .dcache_miss_req_index_o,

      .dcache_refill_valid_i,
      .dcache_refill_ready_o,
      .dcache_refill_paddr_i,
      .dcache_refill_way_i,
      .dcache_refill_data_i,

      .dcache_wb_req_valid_o,
      .dcache_wb_req_ready_i,
      .dcache_wb_req_paddr_o,
      .dcache_wb_req_data_o
  );

  // Expose backend commit signals
  assign commit_valid_o = dut.u_backend.commit_valid;
  assign commit_we_o    = dut.u_backend.commit_we;
  assign commit_areg_o  = dut.u_backend.commit_areg;
  assign commit_wdata_o = dut.u_backend.commit_wdata;
  assign commit_pc_o    = dut.u_backend.commit_pc;
  assign backend_flush_o = dut.u_backend.backend_flush_o;
  assign backend_redirect_pc_o = dut.u_backend.backend_redirect_pc_o;

  // Debug: frontend/backend handshakes
  assign dbg_fe_valid_o = dut.fe_ibuf_valid;
  assign dbg_fe_ready_o = dut.fe_ibuf_ready;
  assign dbg_fe_pc_o    = dut.fe_ibuf_pc;
  assign dbg_fe_instrs_o = dut.fe_ibuf_instrs;
  assign dbg_dec_valid_o = dut.u_backend.decode_ibuf_valid;
  assign dbg_dec_ready_o = dut.u_backend.decode_ibuf_ready;
  assign dbg_rob_ready_o = dut.u_backend.rob_ready;

  // Debug: LSU load path
  assign dbg_lsu_ld_req_valid_o = dut.u_backend.lsu_ld_req_valid;
  assign dbg_lsu_ld_req_ready_o = dut.u_backend.lsu_ld_req_ready;
  assign dbg_lsu_ld_req_addr_o  = dut.u_backend.lsu_ld_req_addr;
  assign dbg_lsu_ld_rsp_valid_o = dut.u_backend.lsu_ld_rsp_valid;
  assign dbg_lsu_ld_rsp_ready_o = dut.u_backend.lsu_ld_rsp_ready;
  assign dbg_lsu_issue_valid_o  = dut.u_backend.lsu_en;
  assign dbg_lsu_req_ready_o    = dut.u_backend.lsu_req_ready;
  assign dbg_lsu_issue_ready_o  = dut.u_backend.lsu_issue_ready;
  assign dbg_lsu_free_count_o   = dut.u_backend.lsu_free_count;
  assign dbg_lsu_rs_busy_o      = dut.u_backend.u_issue_lsu.u_rs.busy;
  assign dbg_lsu_rs_ready_o     = dut.u_backend.u_issue_lsu.u_rs.ready_mask;

  logic [Cfg.RS_DEPTH-1:0] lsu_rs_head_match;
  logic lsu_rs_head_found;
  logic [$clog2(Cfg.RS_DEPTH)-1:0] lsu_rs_head_idx;

  always_comb begin
    lsu_rs_head_match = '0;
    for (int i = 0; i < Cfg.RS_DEPTH; i++) begin
      if (dut.u_backend.u_issue_lsu.u_rs.busy[i] &&
          (dut.u_backend.u_issue_lsu.u_rs.dst_arr[i] == dut.u_backend.rob_head_ptr)) begin
        lsu_rs_head_match[i] = 1'b1;
      end
    end
  end

  always_comb begin
    lsu_rs_head_found = 1'b0;
    lsu_rs_head_idx = '0;
    for (int i = 0; i < Cfg.RS_DEPTH; i++) begin
      if (!lsu_rs_head_found && lsu_rs_head_match[i]) begin
        lsu_rs_head_found = 1'b1;
        lsu_rs_head_idx = i[$clog2(Cfg.RS_DEPTH)-1:0];
      end
    end
  end

  assign dbg_lsu_rs_head_match_o = lsu_rs_head_match;
  assign dbg_lsu_rs_head_valid_o = lsu_rs_head_found;
  assign dbg_lsu_rs_head_idx_o   = lsu_rs_head_idx;
  assign dbg_lsu_rs_head_dst_o   = lsu_rs_head_found
                                  ? dut.u_backend.u_issue_lsu.u_rs.dst_arr[lsu_rs_head_idx]
                                  : '0;
  assign dbg_lsu_rs_head_r1_ready_o = lsu_rs_head_found
                                     ? dut.u_backend.u_issue_lsu.u_rs.r1_arr[lsu_rs_head_idx]
                                     : 1'b0;
  assign dbg_lsu_rs_head_r2_ready_o = lsu_rs_head_found
                                     ? dut.u_backend.u_issue_lsu.u_rs.r2_arr[lsu_rs_head_idx]
                                     : 1'b0;
  assign dbg_lsu_rs_head_q1_o = lsu_rs_head_found
                              ? dut.u_backend.u_issue_lsu.u_rs.q1_arr[lsu_rs_head_idx]
                              : '0;
  assign dbg_lsu_rs_head_q2_o = lsu_rs_head_found
                              ? dut.u_backend.u_issue_lsu.u_rs.q2_arr[lsu_rs_head_idx]
                              : '0;
  assign dbg_lsu_rs_head_has_rs1_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].has_rs1
                                   : 1'b0;
  assign dbg_lsu_rs_head_has_rs2_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].has_rs2
                                   : 1'b0;
  assign dbg_lsu_rs_head_is_store_o = lsu_rs_head_found
                                    ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].is_store
                                    : 1'b0;
  assign dbg_lsu_rs_head_is_load_o = lsu_rs_head_found
                                   ? dut.u_backend.u_issue_lsu.u_rs.op_arr[lsu_rs_head_idx].is_load
                                   : 1'b0;
  assign dbg_lsu_rs_head_sb_id_o = lsu_rs_head_found
                                 ? dut.u_backend.u_issue_lsu.u_rs.sb_arr[lsu_rs_head_idx]
                                 : '0;

  // Debug: Store buffer / D$ store path
  assign dbg_sb_alloc_req_o = dut.u_backend.sb_alloc_req;
  assign dbg_sb_alloc_ready_o = dut.u_backend.sb_alloc_ready;
  assign dbg_sb_alloc_fire_o  = dut.u_backend.sb_alloc_fire;
  assign dbg_sb_dcache_req_valid_o = dut.u_backend.sb_dcache_req_valid;
  assign dbg_sb_dcache_req_ready_o = dut.u_backend.sb_dcache_req_ready;
  assign dbg_sb_dcache_req_addr_o  = dut.u_backend.sb_dcache_req_addr;
  assign dbg_sb_dcache_req_data_o  = dut.u_backend.sb_dcache_req_data;

  // Debug: ROB head state
  assign dbg_rob_head_fu_o       = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].fu_type;
  assign dbg_rob_head_complete_o = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].complete;
  assign dbg_rob_head_is_store_o = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].is_store;
  assign dbg_rob_head_pc_o       = dut.u_backend.u_rob.rob_ram[dut.u_backend.u_rob.head_ptr_q].pc;
  assign dbg_rob_count_o         = dut.u_backend.u_rob.count_q;
  assign dbg_rob_head_ptr_o      = dut.u_backend.u_rob.head_ptr_q;
  assign dbg_rob_tail_ptr_o      = dut.u_backend.u_rob.tail_ptr_q;

  logic [ROB_IDX_W-1:0] rob_q2_idx;
  always_comb begin
    if (lsu_rs_head_found) begin
      rob_q2_idx = dut.u_backend.u_issue_lsu.u_rs.q2_arr[lsu_rs_head_idx];
    end else begin
      rob_q2_idx = '0;
    end
  end

  assign dbg_rob_q2_valid_o = lsu_rs_head_found;
  assign dbg_rob_q2_idx_o   = rob_q2_idx;
  assign dbg_rob_q2_fu_o    = lsu_rs_head_found
                              ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].fu_type
                              : '0;
  assign dbg_rob_q2_complete_o = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].complete
                                : 1'b0;
  assign dbg_rob_q2_is_store_o = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].is_store
                                : 1'b0;
  assign dbg_rob_q2_pc_o       = lsu_rs_head_found
                                ? dut.u_backend.u_rob.rob_ram[rob_q2_idx].pc
                                : '0;

  // Debug: Store Buffer head state
  assign dbg_sb_count_o          = dut.u_backend.u_sb.count;
  assign dbg_sb_head_ptr_o       = dut.u_backend.u_sb.head_ptr;
  assign dbg_sb_tail_ptr_o       = dut.u_backend.u_sb.tail_ptr;
  assign dbg_sb_head_valid_o     = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].valid;
  assign dbg_sb_head_committed_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].committed;
  assign dbg_sb_head_addr_valid_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].addr_valid;
  assign dbg_sb_head_data_valid_o = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].data_valid;
  assign dbg_sb_head_addr_o      = dut.u_backend.u_sb.mem[dut.u_backend.u_sb.head_ptr].addr;

  // Debug: BRU info (from backend execute)
  assign dbg_bru_mispred_o  = dut.u_backend.bru_mispred;
  assign dbg_bru_pc_o       = dut.u_backend.bru_uop.pc;
  assign dbg_bru_imm_o      = dut.u_backend.bru_uop.imm;
  assign dbg_bru_op_o       = dut.u_backend.bru_uop.br_op;
  assign dbg_bru_is_jump_o  = dut.u_backend.bru_uop.is_jump;
  assign dbg_bru_is_branch_o = dut.u_backend.bru_uop.is_branch;
  assign dbg_bru_valid_o    = dut.u_backend.bru_en;

  // Perf counters
  logic [1:0] ifu_state;
  logic [1:0] icache_state;
  logic [1:0] lsu_state;
  logic [2:0] dcache_state;

  assign ifu_state = dut.u_frontend.i_ifu.current_state;
  assign icache_state = dut.u_frontend.i_icache.state_q;
  assign lsu_state = dut.u_backend.u_lsu.state_q;
  assign dcache_state = dut.u_backend.u_dcache.state_q;

  logic [2:0] commit_count;
  always_comb begin
    commit_count = '0;
    for (int i = 0; i < Cfg.NRET; i++) begin
      if (commit_valid_o[i]) commit_count++;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      perf_cycles_o <= 64'd0;
      perf_commit_cycles_o <= 64'd0;
      perf_commit_instrs_o <= 64'd0;
      perf_nocommit_cycles_o <= 64'd0;
      perf_fe_empty_cycles_o <= 64'd0;
      perf_fe_stall_cycles_o <= 64'd0;
      perf_dec_stall_cycles_o <= 64'd0;
      perf_rob_full_cycles_o <= 64'd0;
      perf_issue_full_cycles_o <= 64'd0;
      perf_alu_full_cycles_o <= 64'd0;
      perf_bru_full_cycles_o <= 64'd0;
      perf_lsu_full_cycles_o <= 64'd0;
      perf_csr_full_cycles_o <= 64'd0;
      perf_sb_full_cycles_o <= 64'd0;
      perf_icache_miss_cycles_o <= 64'd0;
      perf_dcache_miss_cycles_o <= 64'd0;
      perf_flush_cycles_o <= 64'd0;
      perf_icache_miss_reqs_o <= 64'd0;
      perf_dcache_miss_reqs_o <= 64'd0;
      perf_ifu_start_cycles_o <= 64'd0;
      perf_ifu_wait_icache_cycles_o <= 64'd0;
      perf_ifu_wait_ibuf_cycles_o <= 64'd0;
      perf_icache_idle_cycles_o <= 64'd0;
      perf_icache_lookup_cycles_o <= 64'd0;
      perf_icache_miss_req_cycles_o <= 64'd0;
      perf_icache_wait_refill_cycles_o <= 64'd0;
      perf_lsu_idle_cycles_o <= 64'd0;
      perf_lsu_ld_req_cycles_o <= 64'd0;
      perf_lsu_ld_rsp_cycles_o <= 64'd0;
      perf_lsu_resp_cycles_o <= 64'd0;
      perf_dcache_idle_cycles_o <= 64'd0;
      perf_dcache_lookup_cycles_o <= 64'd0;
      perf_dcache_store_write_cycles_o <= 64'd0;
      perf_dcache_wb_req_cycles_o <= 64'd0;
      perf_dcache_miss_req_cycles_o <= 64'd0;
      perf_dcache_wait_refill_cycles_o <= 64'd0;
      perf_dcache_resp_cycles_o <= 64'd0;
    end else begin
      perf_cycles_o <= perf_cycles_o + 1;
      if (|commit_valid_o) begin
        perf_commit_cycles_o <= perf_commit_cycles_o + 1;
      end else begin
        perf_nocommit_cycles_o <= perf_nocommit_cycles_o + 1;
      end
      perf_commit_instrs_o <= perf_commit_instrs_o + commit_count;

      if (!dbg_fe_valid_o) perf_fe_empty_cycles_o <= perf_fe_empty_cycles_o + 1;
      if (dbg_fe_valid_o && !dbg_fe_ready_o) begin
        perf_fe_stall_cycles_o <= perf_fe_stall_cycles_o + 1;
      end
      if (dbg_dec_valid_o && !dbg_dec_ready_o) begin
        perf_dec_stall_cycles_o <= perf_dec_stall_cycles_o + 1;
      end
      if (dut.u_backend.dec_valid && !dut.u_backend.rob_ready) begin
        perf_rob_full_cycles_o <= perf_rob_full_cycles_o + 1;
      end
      if (dut.u_backend.dec_valid && dut.u_backend.rob_ready &&
          !dut.u_backend.rob_ready_gated) begin
        perf_issue_full_cycles_o <= perf_issue_full_cycles_o + 1;
      end
      if (dut.u_backend.dec_valid && dut.u_backend.rob_ready &&
          !dut.u_backend.alu_can_accept) begin
        perf_alu_full_cycles_o <= perf_alu_full_cycles_o + 1;
      end
      if (dut.u_backend.dec_valid && dut.u_backend.rob_ready &&
          !dut.u_backend.bru_can_accept) begin
        perf_bru_full_cycles_o <= perf_bru_full_cycles_o + 1;
      end
      if (dut.u_backend.dec_valid && dut.u_backend.rob_ready &&
          !dut.u_backend.lsu_can_accept) begin
        perf_lsu_full_cycles_o <= perf_lsu_full_cycles_o + 1;
      end
      if (dut.u_backend.dec_valid && dut.u_backend.rob_ready &&
          !dut.u_backend.csr_can_accept) begin
        perf_csr_full_cycles_o <= perf_csr_full_cycles_o + 1;
      end
      if ((|dut.u_backend.sb_alloc_req) && !dut.u_backend.sb_alloc_ready) begin
        perf_sb_full_cycles_o <= perf_sb_full_cycles_o + 1;
      end
      if (icache_miss_req_valid_o && !icache_miss_req_ready_i) begin
        perf_icache_miss_cycles_o <= perf_icache_miss_cycles_o + 1;
      end
      if (dcache_miss_req_valid_o && !dcache_miss_req_ready_i) begin
        perf_dcache_miss_cycles_o <= perf_dcache_miss_cycles_o + 1;
      end
      if (backend_flush_o) perf_flush_cycles_o <= perf_flush_cycles_o + 1;
      if (icache_miss_req_valid_o) begin
        perf_icache_miss_reqs_o <= perf_icache_miss_reqs_o + 1;
      end
      if (dcache_miss_req_valid_o) begin
        perf_dcache_miss_reqs_o <= perf_dcache_miss_reqs_o + 1;
      end

      unique case (ifu_state)
        IFU_S_START: perf_ifu_start_cycles_o <= perf_ifu_start_cycles_o + 1;
        IFU_S_WAIT_ICACHE:
          perf_ifu_wait_icache_cycles_o <= perf_ifu_wait_icache_cycles_o + 1;
        IFU_S_WAIT_IBUFFER:
          perf_ifu_wait_ibuf_cycles_o <= perf_ifu_wait_ibuf_cycles_o + 1;
        default: ;
      endcase

      unique case (icache_state)
        ICACHE_S_IDLE: perf_icache_idle_cycles_o <= perf_icache_idle_cycles_o + 1;
        ICACHE_S_LOOKUP:
          perf_icache_lookup_cycles_o <= perf_icache_lookup_cycles_o + 1;
        ICACHE_S_MISS_REQ:
          perf_icache_miss_req_cycles_o <= perf_icache_miss_req_cycles_o + 1;
        ICACHE_S_MISS_WAIT:
          perf_icache_wait_refill_cycles_o <= perf_icache_wait_refill_cycles_o + 1;
        default: ;
      endcase

      unique case (lsu_state)
        LSU_S_IDLE: perf_lsu_idle_cycles_o <= perf_lsu_idle_cycles_o + 1;
        LSU_S_LD_REQ: perf_lsu_ld_req_cycles_o <= perf_lsu_ld_req_cycles_o + 1;
        LSU_S_LD_RSP: perf_lsu_ld_rsp_cycles_o <= perf_lsu_ld_rsp_cycles_o + 1;
        LSU_S_RESP: perf_lsu_resp_cycles_o <= perf_lsu_resp_cycles_o + 1;
        default: ;
      endcase

      unique case (dcache_state)
        DCACHE_S_IDLE: perf_dcache_idle_cycles_o <= perf_dcache_idle_cycles_o + 1;
        DCACHE_S_LOOKUP:
          perf_dcache_lookup_cycles_o <= perf_dcache_lookup_cycles_o + 1;
        DCACHE_S_STORE_WRITE:
          perf_dcache_store_write_cycles_o <= perf_dcache_store_write_cycles_o + 1;
        DCACHE_S_WB_REQ:
          perf_dcache_wb_req_cycles_o <= perf_dcache_wb_req_cycles_o + 1;
        DCACHE_S_MISS_REQ:
          perf_dcache_miss_req_cycles_o <= perf_dcache_miss_req_cycles_o + 1;
        DCACHE_S_WAIT_REFILL:
          perf_dcache_wait_refill_cycles_o <= perf_dcache_wait_refill_cycles_o + 1;
        DCACHE_S_RESP: perf_dcache_resp_cycles_o <= perf_dcache_resp_cycles_o + 1;
        default: ;
      endcase
    end
  end

endmodule
