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
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0;
  top->ld_rsp_err_i = 0;

  top->wb_ready_i = 1;

  top->lq_test_alloc_valid_i = 0;
  top->lq_test_alloc_rob_tag_i = 0;
  top->lq_test_pop_valid_i = 0;

  top->sq_test_alloc_valid_i = 0;
  top->sq_test_alloc_rob_tag_i = 0;
  top->sq_test_pop_valid_i = 0;
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
  top->ld_rsp_id_i = 0;
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
  top->ld_rsp_id_i = 1;
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

static void test_group_allows_new_req_when_older_lane_waits(Vtb_lsu *top) {
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
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x11112222;
  top->ld_rsp_err_i = 0;
  tick(top);  // lane0 -> S_RESP
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: first load writeback");
  expect(top->wb_rob_idx_o == 0x10, "LSU group order: first wb tag");
  tick(top);  // lane0 -> S_IDLE, lane1 still waiting

  // 4) While lane1 (older) waits for D$, lane0 can still accept newer request.
  top->ld_req_ready_i = 0; // keep D$ unavailable so lane1 remains pending
  top->req_valid_i = 1;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x8200;
  top->imm_i = 0;
  top->rob_tag_i = 0x12;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU group order: allow newer req when another lane waits");
  tick(top);  // lane0 accepts newer request
  top->req_valid_i = 0;

  // 5) Drain lane0/lane1 requests to reach response state.
  top->ld_req_ready_i = 1;
  tick(top);  // lane0 -> S_LD_RSP
  tick(top);  // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  // 6) Return lane1 first.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x33334444;
  top->ld_rsp_err_i = 0;
  tick(top);  // lane1 -> S_RESP
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: older pending load writeback");
  expect(top->wb_rob_idx_o == 0x11, "LSU group order: older pending load wb tag");
  tick(top);

  // 7) Return newer lane0 load.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x55556666;
  top->ld_rsp_err_i = 0;
  tick(top);  // lane0 -> S_RESP
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU group order: newer load writeback");
  expect(top->wb_rob_idx_o == 0x12, "LSU group order: newer load wb tag");
  tick(top);
}

static void test_group_allows_req_on_rsp_handoff_cycle(Vtb_lsu *top) {
  set_defaults(top);

  // 1) First load -> lane0
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x9000;
  top->imm_i = 0;
  top->rob_tag_i = 0x13;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU handoff: first load accepted");
  tick(top); // lane0 -> S_LD_REQ

  // 2) Second load -> lane1 while lane0 waits for D$ req
  top->ld_req_ready_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0x9100;
  top->imm_i = 4;
  top->rob_tag_i = 0x14;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU handoff: second load accepted");
  tick(top); // lane1 -> S_LD_REQ

  // 3) Grant D$ request for lane0 so owner is established.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU handoff: lane0 request issues");
  expect(top->ld_req_addr_o == 0x9000, "LSU handoff: lane0 request addr");
  tick(top); // lane0 -> S_LD_RSP, owner=lane0

  // 4) In rsp-fire cycle, lane1 is still waiting req.
  // Expected: lane1 request can be issued without one-cycle bubble.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0xAAAA5555;
  top->ld_rsp_err_i = 0;
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU handoff: lane0 response ready");
  expect(top->ld_req_valid_o == 1, "LSU handoff: lane1 request should issue on rsp-fire cycle");
  expect(top->ld_req_addr_o == 0x9104, "LSU handoff: lane1 request addr on rsp-fire cycle");
  expect(top->ld_req_id_o == 1, "LSU handoff: lane1 request id on rsp-fire cycle");
  tick(top); // lane0 rsp consumed, lane1 request should handshake

  // 5) Drain lane0 writeback.
  top->ld_rsp_valid_i = 0;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU handoff: lane0 writeback after rsp");
  expect(top->wb_rob_idx_o == 0x13, "LSU handoff: lane0 wb tag");
  tick(top);

  // 6) Complete lane1 response/writeback to exit cleanly.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x12345678;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU handoff: lane1 response ready");
  tick(top);
  top->ld_rsp_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU handoff: lane1 writeback");
  expect(top->wb_rob_idx_o == 0x14, "LSU handoff: lane1 wb tag");
  tick(top);
}

static void test_group_supports_two_outstanding_with_rsp_id(Vtb_lsu *top) {
  set_defaults(top);

  // 1) First load -> lane0
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0xA000;
  top->imm_i = 0;
  top->rob_tag_i = 0x20;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ooorsp: first load accepted");
  tick(top); // lane0 -> S_LD_REQ

  // 2) Second load -> lane1 while lane0 waits D$ req grant.
  top->ld_req_ready_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0xA100;
  top->imm_i = 4;
  top->rob_tag_i = 0x21;
  top->req_valid_i = 1;
  eval_comb(top);
  expect(top->req_ready_o == 1, "LSU ooorsp: second load accepted");
  tick(top); // lane1 -> S_LD_REQ

  // 3) Fire lane0 load request first.
  top->req_valid_i = 0;
  top->ld_req_ready_i = 1;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU ooorsp: lane0 request valid");
  expect(top->ld_req_addr_o == 0xA000, "LSU ooorsp: lane0 request addr");
  expect(top->ld_req_id_o == 0, "LSU ooorsp: lane0 request id");
  tick(top); // lane0 -> S_LD_RSP

  // 4) Without waiting for lane0 response, lane1 request should also fire.
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "LSU ooorsp: lane1 request valid before lane0 response");
  expect(top->ld_req_addr_o == 0xA104, "LSU ooorsp: lane1 request addr");
  expect(top->ld_req_id_o == 1, "LSU ooorsp: lane1 request id");
  tick(top); // lane1 -> S_LD_RSP
  top->ld_req_ready_i = 0;

  // 5) Return lane1 response first (out-of-order by request issue order).
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x56781234;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU ooorsp: lane1 response ready");
  tick(top); // lane1 -> S_RESP
  top->ld_rsp_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU ooorsp: lane1 writeback first");
  expect(top->wb_rob_idx_o == 0x21, "LSU ooorsp: lane1 wb tag");
  expect(top->wb_data_o == 0x56781234, "LSU ooorsp: lane1 wb data");
  tick(top);

  // 6) Return lane0 response later.
  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 0;
  top->ld_rsp_data_i = 0x89ABCDEF;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "LSU ooorsp: lane0 response ready");
  tick(top); // lane0 -> S_RESP
  top->ld_rsp_valid_i = 0;

  eval_comb(top);
  expect(top->wb_valid_o == 1, "LSU ooorsp: lane0 writeback second");
  expect(top->wb_rob_idx_o == 0x20, "LSU ooorsp: lane0 wb tag");
  expect(top->wb_data_o == 0x89ABCDEF, "LSU ooorsp: lane0 wb data");
  tick(top);
}

static void test_sq_forwarding_store_to_younger_load_without_dcache_rsp(Vtb_lsu *top) {
  set_defaults(top);

  // 1) Hold writeback so the store stays resident while younger load issues.
  top->wb_ready_i = 0;

  // 2) Older store enters LSU/SQ.
  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0xB000;
  top->imm_i = 0;
  top->rs2_data_i = 0xDEADBEEF;
  top->rob_tag_i = 0x22;
  eval_comb(top);
  expect(top->req_ready_o == 1, "SQ fwd: older store accepted");
  tick(top); // lane0 store -> S_RESP (blocked by wb_ready=0)

  // 3) Younger load to same address should forward from SQ path.
  top->req_valid_i = 1;
  top->is_store_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0xB000;
  top->imm_i = 0;
  top->rob_tag_i = 0x23;
  eval_comb(top);
  expect(top->req_ready_o == 1, "SQ fwd: younger load accepted");
  expect(top->ld_req_valid_o == 0, "SQ fwd: load should bypass dcache request");
  tick(top); // lane1 load should become S_RESP directly

  top->req_valid_i = 0;
  eval_comb(top);
  expect(top->ld_req_valid_o == 0, "SQ fwd: still no dcache request");

  // 4) Release writeback: store retires first, then load returns forwarded data.
  top->wb_ready_i = 1;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "SQ fwd: store writeback appears first");
  expect(top->wb_rob_idx_o == 0x22, "SQ fwd: first wb tag is store");
  tick(top);

  eval_comb(top);
  expect(top->wb_valid_o == 1, "SQ fwd: forwarded load writeback appears");
  expect(top->wb_rob_idx_o == 0x23, "SQ fwd: second wb tag is load");
  expect(top->wb_data_o == 0xDEADBEEF, "SQ fwd: load gets forwarded store data");
  tick(top);
}

static void test_sq_forwarding_lbu_with_byte_offset(Vtb_lsu *top) {
  set_defaults(top);

  // Keep older store resident so younger load must forward from SQ.
  top->wb_ready_i = 0;

  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0xB100;
  top->imm_i = 0;
  top->rs2_data_i = 0x00005500;  // byte@+1 = 0x55, byte@+0 = 0x00
  top->rob_tag_i = 0x24;
  eval_comb(top);
  expect(top->req_ready_o == 1, "SQ fwd LBU+1: older store accepted");
  tick(top);

  top->req_valid_i = 1;
  top->is_store_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LBU;
  top->rs1_data_i = 0xB100;
  top->imm_i = 1;
  top->rob_tag_i = 0x25;
  eval_comb(top);
  expect(top->req_ready_o == 1, "SQ fwd LBU+1: younger load accepted");
  expect(top->ld_req_valid_o == 0, "SQ fwd LBU+1: load bypasses dcache");
  tick(top);

  top->req_valid_i = 0;
  top->wb_ready_i = 1;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "SQ fwd LBU+1: store writeback first");
  expect(top->wb_rob_idx_o == 0x24, "SQ fwd LBU+1: first wb tag is store");
  tick(top);

  eval_comb(top);
  expect(top->wb_valid_o == 1, "SQ fwd LBU+1: forwarded load writeback appears");
  expect(top->wb_rob_idx_o == 0x25, "SQ fwd LBU+1: second wb tag is load");
  expect(top->wb_data_o == 0x00000055, "SQ fwd LBU+1: load gets forwarded byte at +1");
  tick(top);
}

static void test_sq_does_not_forward_from_younger_store(Vtb_lsu *top) {
  set_defaults(top);

  // Keep younger store resident in SQ while issuing an older load.
  top->wb_ready_i = 0;

  // Younger store (larger ROB tag) issues first.
  top->req_valid_i = 1;
  top->is_store_i = 1;
  top->is_load_i = 0;
  top->lsu_op_i = LSU_SW;
  top->rs1_data_i = 0xB200;
  top->imm_i = 0;
  top->rs2_data_i = 0x55667788;
  top->rob_tag_i = 0x25;
  eval_comb(top);
  expect(top->req_ready_o == 1, "SQ age: younger store accepted");
  tick(top);

  // Older load to same address must not forward from that younger store.
  top->req_valid_i = 1;
  top->is_store_i = 0;
  top->is_load_i = 1;
  top->lsu_op_i = LSU_LW;
  top->rs1_data_i = 0xB200;
  top->imm_i = 0;
  top->rob_tag_i = 0x22;
  eval_comb(top);
  expect(top->req_ready_o == 1, "SQ age: older load accepted");
  tick(top);

  top->req_valid_i = 0;
  eval_comb(top);
  expect(top->ld_req_valid_o == 1, "SQ age: older load must go to dcache");
  expect(top->ld_req_addr_o == 0xB200, "SQ age: dcache addr matches load");
  expect(top->ld_req_id_o == 1, "SQ age: older load issued on lane1");

  top->ld_req_ready_i = 1;
  tick(top);
  top->ld_req_ready_i = 0;

  top->ld_rsp_valid_i = 1;
  top->ld_rsp_id_i = 1;
  top->ld_rsp_data_i = 0x11223344;
  top->ld_rsp_err_i = 0;
  eval_comb(top);
  expect(top->ld_rsp_ready_o == 1, "SQ age: load response accepted");
  tick(top);
  top->ld_rsp_valid_i = 0;

  // Release writeback: store may retire first, then load with dcache data.
  top->wb_ready_i = 1;
  eval_comb(top);
  expect(top->wb_valid_o == 1, "SQ age: first writeback appears");
  expect(top->wb_rob_idx_o == 0x25, "SQ age: younger store writes first");
  tick(top);

  eval_comb(top);
  expect(top->wb_valid_o == 1, "SQ age: second writeback appears");
  expect(top->wb_rob_idx_o == 0x22, "SQ age: older load writes second");
  expect(top->wb_data_o == 0x11223344, "SQ age: load uses dcache data, not younger store");
  tick(top);
}

static void test_lq_queue_occupancy_four_entries(Vtb_lsu *top) {
  set_defaults(top);

  for (uint32_t i = 0; i < 4; i++) {
    top->lq_test_alloc_valid_i = 1;
    top->lq_test_alloc_rob_tag_i = 0x20 + i;
    eval_comb(top);
    expect(top->lq_test_alloc_ready_o == 1, "LQ queue: alloc ready for 4-entry fill");
    tick(top);
  }

  top->lq_test_alloc_valid_i = 0;
  eval_comb(top);
  expect(top->lq_test_count_o == 4, "LQ queue: occupancy reaches 4");
  expect(top->lq_test_head_valid_o == 1, "LQ queue: head valid after fill");
  expect(top->lq_test_head_rob_tag_o == 0x20, "LQ queue: oldest entry remains at head");

  top->lq_test_pop_valid_i = 1;
  for (uint32_t i = 0; i < 4; i++) {
    eval_comb(top);
    expect(top->lq_test_pop_ready_o == 1, "LQ queue: pop ready while non-empty");
    expect(top->lq_test_head_rob_tag_o == (0x20 + i), "LQ queue: pop order is FIFO");
    tick(top);
  }
  top->lq_test_pop_valid_i = 0;

  eval_comb(top);
  expect(top->lq_test_count_o == 0, "LQ queue: occupancy returns to zero");
  expect(top->lq_test_head_valid_o == 0, "LQ queue: head invalid when empty");
}

static void test_sq_queue_ordered_dequeue_contract(Vtb_lsu *top) {
  set_defaults(top);

  for (uint32_t i = 0; i < 3; i++) {
    top->sq_test_alloc_valid_i = 1;
    top->sq_test_alloc_rob_tag_i = 0x30 + i;
    eval_comb(top);
    expect(top->sq_test_alloc_ready_o == 1, "SQ queue: alloc ready for ordered fill");
    tick(top);
  }

  top->sq_test_alloc_valid_i = 0;
  eval_comb(top);
  expect(top->sq_test_count_o == 3, "SQ queue: occupancy reaches 3");
  expect(top->sq_test_head_valid_o == 1, "SQ queue: head valid after fill");
  expect(top->sq_test_head_rob_tag_o == 0x30, "SQ queue: oldest store at head");

  top->sq_test_pop_valid_i = 1;
  for (uint32_t i = 0; i < 3; i++) {
    eval_comb(top);
    expect(top->sq_test_pop_ready_o == 1, "SQ queue: pop ready while entries exist");
    expect(top->sq_test_head_rob_tag_o == (0x30 + i), "SQ queue: ordered dequeue");
    tick(top);
  }
  top->sq_test_pop_valid_i = 0;

  eval_comb(top);
  expect(top->sq_test_count_o == 0, "SQ queue: occupancy returns to zero");
  expect(top->sq_test_head_valid_o == 0, "SQ queue: head invalid when empty");
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
  test_group_allows_new_req_when_older_lane_waits(top);
  test_group_allows_req_on_rsp_handoff_cycle(top);
  test_group_supports_two_outstanding_with_rsp_id(top);
  test_sq_forwarding_store_to_younger_load_without_dcache_rsp(top);
  test_sq_forwarding_lbu_with_byte_offset(top);
  test_sq_does_not_forward_from_younger_store(top);
  test_lq_queue_occupancy_four_entries(top);
  test_sq_queue_ordered_dequeue_contract(top);

  std::cout << ANSI_RES_GRN << "--- [ALL LSU TESTS PASSED] ---" << ANSI_RES_RST << std::endl;

  delete top;
  return 0;
}
