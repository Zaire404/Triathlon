#include "Vtb_bpu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <iostream>

const int INSTR_PER_FETCH = 4;
vluint64_t sim_time = 0;
void tick(Vtb_bpu *top, int cnt) {
  while(cnt --) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
}

void reset(Vtb_bpu *top) {
  top->rst_i = 1; 
  tick(top, 5);
  top->rst_i = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_bpu *top = new Vtb_bpu;
  reset(top);
  std::cout << "Checking PLEN..." << std::endl;
  top->pc_i = 0x80000000;
  tick(top, 1);
  assert(top->npc_o == 0x80000000 + 16);
  std::cout << "--- [PASSED] All checks passed successfully! ---" << std::endl;
  delete top;
  return 0;
}