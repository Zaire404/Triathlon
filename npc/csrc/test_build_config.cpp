// csrc/test_build_config.cpp
#include "Vtb_build_config.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iostream>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_build_config *top = new Vtb_build_config;

  std::cout << "--- [START] Running C++ test for build_config function ---"
            << std::endl;

  // 1. 设置输入值，直接访问独立的输入端口
  top->i_XLEN = 32;
  top->i_VLEN = 32;
  top->i_ILEN = 32;
  top->i_INSTR_PER_FETCH = 4;
  top->i_ICACHE_BYTE_SIZE = 8192;
  top->i_ICACHE_SET_ASSOC = 8;
  top->i_ICACHE_LINE_WIDTH = 64;

  // 2. 执行模块逻辑
  top->eval();

  // 3. 计算预期结果
  int expected_plen = 32;
  int expected_assoc_width = 3;
  int expected_index_width = 7;
  int expected_tag_width = 22;

  // 4. 读取输出并验证，访问独立的输出端口
  std::cout << "Checking PLEN..." << std::endl;
  assert(top->o_PLEN == expected_plen);

  std::cout << "Checking ICACHE_SET_ASSOC_WIDTH..." << std::endl;
  assert(top->o_ICACHE_SET_ASSOC_WIDTH == expected_assoc_width);

  std::cout << "Checking ICACHE_INDEX_WIDTH..." << std::endl;
  assert(top->o_ICACHE_INDEX_WIDTH == expected_index_width);

  std::cout << "Checking ICACHE_TAG_WIDTH..." << std::endl;
  assert(top->o_ICACHE_TAG_WIDTH == expected_tag_width);

  std::cout << "Checking metadata fields are wired..." << std::endl;
  assert(top->o_UOP_PRED_NPC == 0);
  assert(top->o_IBUF_SLOT_VALID == 0);
  assert(top->o_IBUF_PRED_NPC == 0);

  std::cout << "--- [PASSED] All checks passed successfully! ---" << std::endl;

  // 5. 清理
  delete top;
  return 0;
}
