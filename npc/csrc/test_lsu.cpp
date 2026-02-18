#include "Vtb_lsu.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>

#define ANSI_RES_GRN "\x1b[32m"
#define ANSI_RES_RED "\x1b[31m"
#define ANSI_RES_RST "\x1b[0m"

static void tick(Vtb_lsu *top) {
  top->clk_i = 0;
  top->eval();
  top->clk_i = 1;
  top->eval();
}

static void eval_comb(Vtb_lsu *top) {
  top->clk_i = 0;
  top->eval();
}

static void reset(Vtb_lsu *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  tick(top);
  tick(top);
  top->rst_ni = 1;
  tick(top);
}

static void set_defaults(Vtb_lsu *top) {
  top->flush_i = 0;
  top->req_valid_i = 0;
  top->is_load_i = 0;
  top->is_store_i = 0;
  top->lsu_op_i = 0;
  top->imm_i = 0;
  top->rs1_data_i = 0;
  top->rs2_data_i = 0;
  top->rob_tag_i = 0;
  top->sb_id_i = 0;

  top->sb_load_hit_i = 0;
  top->sb_load_data_i = 0;

  top->ld_req_ready_i = 0;
  top->ld_rsp_valid_i = 0;
  top->ld_rsp_data_i = 0;
  top->ld_rsp_err_i = 0;

  top->wb_ready_i = 1;
}

static void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cout << "[ " << ANSI_RES_RED << "FAIL" << ANSI_RES_RST << " ] " << msg << "\n";
    std::exit(1);
  } else {
    std::cout << "[ " << ANSI_RES_GRN << "PASS" << ANSI_RES_RST << " ] " << msg << "\n";
  }
}

enum {
  LSU_LB = 0,
  LSU_LH = 1,
  LSU_LW = 2,
  LSU_LD = 3,
  LSU_LBU = 4,
  LSU_LHU = 5,
  LSU_LWU = 6,
  LSU_SB = 7,
  LSU_SH = 8,
  LSU_SW = 9,
  LSU_SD = 10
};

static void test_store_aligned(Vtb_lsu *top) {
  set_defaults(top);
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x1000;
  top->imm_i = 4;
  top->rs2_data_i = 0xA5A5A5A5;
  top->rob_tag_i = 0x3;
  top->sb_id_i = 0x5;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Store aligned: req_ready");
  expect(top->sb_ex_valid_o == 1, "Store aligned: sb_ex_valid");
  expect(top->sb_ex_addr_o == 0x1004, "Store aligned: sb_ex_addr");
  expect(top->sb_ex_data_o == 0xA5A5A5A5, "Store aligned: sb_ex_data");
  expect(top->sb_ex_sb_id_o == 0x5, "Store aligned: sb_ex_sb_id");

  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Store aligned: wb_valid");
  expect(top->wb_exception_o == 0, "Store aligned: wb_exception");
  expect(top->wb_rob_idx_o == 0x3, "Store aligned: wb_rob_idx");

  tick(top);
}

static void test_store_misaligned(Vtb_lsu *top) {
  set_defaults(top);
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x1000;
  top->imm_i = 2; // misaligned for SW
  top->rs2_data_i = 0x11111111;
  top->rob_tag_i = 0x4;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Store misaligned: req_ready");
  expect(top->sb_ex_valid_o == 0, "Store misaligned: sb_ex_valid should be 0");

  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Store misaligned: wb_valid");
  expect(top->wb_exception_o == 1, "Store misaligned: wb_exception");
  expect(top->wb_ecause_o == 6, "Store misaligned: ecause=6");

  tick(top);
}

static void test_load_forward_lb(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LB;
  top->rs1_data_i = 0x2000;
  top->imm_i = 0;
  top->rob_tag_i = 0x7;
  top->sb_load_hit_i = 1;
  top->sb_load_data_i = 0x00000080; // sign-extend to 0xFFFFFF80
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load fwd LB: req_ready");
  expect(top->sb_load_addr_o == 0x2000, "Load fwd LB: sb_load_addr");

  tick(top);
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Load fwd LB: wb_valid");
  expect(top->wb_exception_o == 0, "Load fwd LB: wb_exception");
  expect(top->wb_data_o == 0xFFFFFF80u, "Load fwd LB: wb_data sign-extend");

  tick(top);
}

static void test_load_dcache_ok(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x3000;
  top->imm_i = 4;
  top->rob_tag_i = 0x9;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load D$ ok: req_ready");

  tick(top); // accept request -> S_LD_REQ
  top->req_valid_i = 0;

  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "Load D$ ok: ld_req_valid");
  expect(top->ld_req_addr_o == 0x3004, "Load D$ ok: ld_req_addr");
  expect(top->ld_req_op_o == LSU_LW, "Load D$ ok: ld_req_op");

  tick(top); // move to S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0x12345678;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "Load D$ ok: ld_rsp_ready");

  tick(top); // capture response -> S_RESP
  top->ld_rsp_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Load D$ ok: wb_valid");
  expect(top->wb_exception_o == 0, "Load D$ ok: wb_exception");
  expect(top->wb_data_o == 0x12345678, "Load D$ ok: wb_data");

  tick(top);
}

static void test_load_misaligned(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x3000;
  top->imm_i = 2; // misaligned for LW
  top->rob_tag_i = 0xA;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load misaligned: req_ready");

  tick(top); // S_RESP
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Load misaligned: wb_valid");
  expect(top->wb_exception_o == 1, "Load misaligned: wb_exception");
  expect(top->wb_ecause_o == 4, "Load misaligned: ecause=4");
  expect(top->ld_req_valid_o == 0, "Load misaligned: no dcache req");

  tick(top);
}

static void test_load_access_fault(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x4000;
  top->imm_i = 0;
  top->rob_tag_i = 0xB;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Load access fault: req_ready");

  tick(top); // S_LD_REQ
  top->req_valid_i = 0;

  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "Load access fault: ld_req_valid");

  tick(top); // S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0xDEADBEEF;
  top->ld_rsp_err_i = 1;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "Load access fault: ld_rsp_ready");

  tick(top); // S_RESP
  top->ld_rsp_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Load access fault: wb_valid");
  expect(top->wb_exception_o == 1, "Load access fault: wb_exception");
  expect(top->wb_ecause_o == 5, "Load access fault: ecause=5");

  tick(top);
}

static void test_group_accepts_second_req_when_first_waits_dcache(Vtb_lsu *top) {
  set_defaults(top);
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x5000;
  top->imm_i = 0;
  top->rob_tag_i = 0xC;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group: first load accepted");

  tick(top); // lane0 -> S_LD_REQ

  // Keep lane0 waiting for D$ request grant, then issue second load.
  top->ld_req_ready_i = 0;
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x6000;
  top->imm_i = 4;
  top->rob_tag_i = 0xD;

  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group: second load accepted on free lane");
  expect(top->ld_req_valid_o == 1, "LSU group: D$ request stays valid for first load");
  expect(top->ld_req_addr_o == 0x5000, "LSU group: D$ request address remains first load");

  tick(top); // lane1 -> S_LD_REQ

  // Both lanes are busy now, so a third request must be blocked.
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->is_store_i = 0;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x7000;
  top->imm_i = 8;
  top->rob_tag_i = 0xE;
  eval_comb(top);
  expect(top->req_ready_o == 0, "LSU group: third load blocked when both lanes busy");

  // Complete first request then second request so testcase can exit cleanly.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  tick(top); // lane0 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0xCAFEBABE;
  top->ld_rsp_err_i = 0;
  tick(top); // lane0 -> S_RESP
  top->ld_rsp_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group: first load eventually writebacks");
  expect(top->wb_rob_idx_o == 0xC, "LSU group: first writeback tag belongs to first load");
  tick(top);

  top->ld_req_ready_i = 1;
  tick(top); // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0x1234ABCD;
  top->ld_rsp_err_i = 0;
  tick(top); // lane1 -> S_RESP
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group: second load eventually writebacks");
  expect(top->wb_rob_idx_o == 0xD, "LSU group: second writeback tag belongs to second load");
  tick(top);
}

static void test_store_can_complete_without_dcache_roundtrip(Vtb_lsu *top) {
  set_defaults(top);
  top->is_store_i = 1;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0x7000;
  top->imm_i = 8;
  top->rs2_data_i = 0x11223344;
  top->rob_tag_i = 0xF;
  top->sb_id_i = 0x3;
  top->req_valid_i = 1;

  eval_comb(top);
  expect(top->req_ready_o == 1, "Store no dcache roundtrip: req_ready");
  expect(top->sb_ex_valid_o == 1, "Store no dcache roundtrip: sb_ex_valid");
  expect(top->ld_req_valid_o == 0, "Store no dcache roundtrip: no ld_req on accept cycle");

  tick(top); // S_RESP
  top->req_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "Store no dcache roundtrip: wb_valid in next cycle");
  expect(top->wb_exception_o == 0, "Store no dcache roundtrip: no exception");
  expect(top->wb_rob_idx_o == 0xF, "Store no dcache roundtrip: wb tag");
  expect(top->ld_req_valid_o == 0, "Store no dcache roundtrip: still no ld_req");
  tick(top);
}

static void test_group_blocks_new_req_when_older_lane_waits(Vtb_lsu *top) {
  set_defaults(top);

  // 1) First load -> lane0 (hold D$ req not ready)
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x8000;
  top->imm_i = 0;
  top->rob_tag_i = 0x10;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group order: first load accepted");
  tick(top);

  // 2) Second load -> lane1 (still block D$ req)
  top->ld_req_ready_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x8100;
  top->imm_i = 0;
  top->rob_tag_i = 0x11;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group order: second load accepted on lane1");
  tick(top);

  // 3) Let lane0 complete first, keep lane1 pending in S_LD_REQ
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  tick(top);  // lane0 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0x11112222;
  top->ld_rsp_err_i = 0;
  tick(top);  // lane0 -> S_RESP
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: first load writeback");
  expect(top->wb_rob_idx_o == 0x10, "LSU group order: first wb tag");
  tick(top);  // lane0 -> S_IDLE, lane1 still waiting

  // 4) While lane1 (older) waits for D$, lane0 must NOT accept newer request.
  top->ld_req_ready_i = 0; // keep D$ unavailable so lane1 remains pending
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x8200;
  top->imm_i = 0;
  top->rob_tag_i = 0x12;
  eval_comb(top);
  expect(top->req_ready_o == 0, "LSU group order: block newer req while older lane waits");

  // 5) Drain lane1 to exit test cleanly.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  tick(top);  // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_data_i = 0x33334444;
  top->ld_rsp_err_i = 0;
  tick(top);  // lane1 -> S_RESP
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: second load writeback");
  expect(top->wb_rob_idx_o == 0x11, "LSU group order: second wb tag");
  tick(top);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_lsu *top = new Vtb_lsu;

  reset(top);

  std::cout << "Running LSU unit tests..." << std::endl;

  test_store_aligned(top);
  test_store_misaligned(top);
  test_load_forward_lb(top);
  test_load_dcache_ok(top);
  test_load_misaligned(top);
  test_load_access_fault(top);
  test_group_accepts_second_req_when_first_waits_dcache(top);
  test_store_can_complete_without_dcache_roundtrip(top);
  test_group_blocks_new_req_when_older_lane_waits(top);

  std::cout << ANSI_RES_GRN << "--- [ALL LSU TESTS PASSED] ---" << ANSI_RES_RST << std::endl;

  delete top;
  return 0;
}
