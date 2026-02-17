#include "Vtb_bpu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <iostream>

const int INSTR_PER_FETCH = 4;
void tick(Vtb_bpu *top, int cnt = 1) {
  while (cnt--) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

void reset(Vtb_bpu *top) {
  top->rst_i = 1;
  top->ifu_ready_i = 1;
  top->ifu_valid_i = 1;
  top->update_valid_i = 0;
  top->update_pc_i = 0;
  top->update_is_cond_i = 0;
  top->update_taken_i = 0;
  top->update_target_i = 0;
  top->pc_i = 0x80000000;
  tick(top, 5);
  top->rst_i = 0;
  tick(top, 1);
}

static void expect_not_taken(Vtb_bpu *top, uint32_t pc) {
  top->pc_i = pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 0);
  assert(top->npc_o == pc + 16);
}

static void train(Vtb_bpu *top, uint32_t pc, bool is_cond, bool taken,
                  uint32_t target) {
  top->update_valid_i = 1;
  top->update_pc_i = pc;
  top->update_is_cond_i = is_cond ? 1 : 0;
  top->update_taken_i = taken ? 1 : 0;
  top->update_target_i = target;
  tick(top, 1);
  top->update_valid_i = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_bpu *top = new Vtb_bpu;
  reset(top);

  // 1) Cold start: default not-taken.
  expect_not_taken(top, 0x80000000);

  // 1.1) Unaligned fetch-group base must still advance by FETCH_WIDTH
  // (not by align_group(pc) + FETCH_WIDTH), otherwise frontend may refetch
  // overlapping instructions after redirect.
  expect_not_taken(top, 0x80000114);

  // 1.2) For unaligned fetch base, prediction slot index is relative to fetch pc.
  // Train a JAL at 0x80000084 (aligned-group slot1). Fetch at 0x84 should see
  // it as local slot0; fetch at 0x88 must not see this branch in-window.
  const uint32_t jal_pc = 0x80000084;
  const uint32_t jal_target = 0x80000028;
  train(top, jal_pc, false, true, jal_target);

  top->pc_i = jal_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->npc_o == jal_target);

  top->pc_i = 0x80000088;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 0);
  assert(top->npc_o == 0x80000098);

  // 2) Train conditional branch as taken, expect taken prediction.
  // group pc = 0x80000040, branch pc = +8 => slot2.
  const uint32_t group_pc = 0x80000040;
  const uint32_t br_pc = group_pc + 8;
  const uint32_t br_target = 0x80000100;

  train(top, br_pc, true, true, br_target);
  train(top, br_pc, true, true, br_target); // drive counter to strongly taken

  top->pc_i = group_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 2);
  assert(top->pred_slot_target_o == br_target);
  assert(top->npc_o == br_target);

  // 3) Hysteresis: one not-taken keeps prediction taken, second flips to NT.
  train(top, br_pc, true, false, br_target);
  top->pc_i = group_pc;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->npc_o == br_target);

  train(top, br_pc, true, false, br_target);
  expect_not_taken(top, group_pc);

  // 4) Window-aware arbitration: if multiple taken branches are in one fetch
  // window, predictor must choose the earliest slot in window.
  const uint32_t win_base = 0x80000100;
  const uint32_t early_br_pc = win_base + 4;   // slot1
  const uint32_t late_br_pc = win_base + 12;   // slot3
  const uint32_t early_target = 0x80001000;
  const uint32_t late_target = 0x80002000;

  // Train both as strongly-taken.
  train(top, early_br_pc, true, true, early_target);
  train(top, early_br_pc, true, true, early_target);
  train(top, late_br_pc, true, true, late_target);
  train(top, late_br_pc, true, true, late_target);

  // Base window: [base+0, +4, +8, +12], earliest taken is slot1.
  top->pc_i = win_base;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 1);
  assert(top->pred_slot_target_o == early_target);
  assert(top->npc_o == early_target);

  // Unaligned base window: [base+4, +8, +12, +16], earliest taken is now slot0.
  top->pc_i = win_base + 4;
  tick(top, 1);
  assert(top->pred_slot_valid_o == 1);
  assert(top->pred_slot_idx_o == 0);
  assert(top->pred_slot_target_o == early_target);
  assert(top->npc_o == early_target);

  std::cout << "--- [PASSED] All checks passed successfully! ---" << std::endl;
  delete top;
  return 0;
}
