// 文件: npc/csrc/test_sram.cpp (修改版)
#include "Vtb_sram.h" // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include <cassert>
#include <iostream>

vluint64_t main_time = 0;

void tick(Vtb_sram *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_sram *top = new Vtb_sram;

  std::cout << "--- [START] Running C++ test for 2R1W SRAM ---" << std::endl;

  // 1. 复位
  top->rst_ni = 0;
  top->we_i = 0;
  top->waddr_i = 0;
  top->wdata_i = 0;
  top->addr_ra_i = 0;
  top->addr_rb_i = 0;
  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试 1: 写入数据 ---
  std::cout << "--- Test 1: Write ---" << std::endl;
  top->we_i = 1;    // 启用写入
  top->waddr_i = 5; // 写入地址 5
  top->wdata_i = 0xCAFEBABE;
  std::cout << "[" << main_time << "] Writing 0xCAFEBABE to addr=5"
            << std::endl;
  tick(top); // 时钟上升沿写入

  top->waddr_i = 10; // 写入地址 10
  top->wdata_i = 0xDEADBEEF;
  std::cout << "[" << main_time << "] Writing 0xDEADBEEF to addr=10"
            << std::endl;
  tick(top); // 时钟上升沿写入

  top->we_i = 0; // 停止写入
  top->eval();

  // --- 测试 2: 同时读取两个不同地址 ---
  std::cout << "--- Test 2: Simultaneous Dual Read ---" << std::endl;
  top->addr_ra_i = 5;  // 端口 A 读取地址 5
  top->addr_rb_i = 10; // 端口 B 读取地址 10
  top->eval();         // 组合逻辑读

  std::cout << "[" << main_time
            << "] Reading Addr 5 (Port A). Got: " << std::hex << top->rdata_ra_o
            << " (Expected: 0xCAFEBABE)" << std::endl;
  assert(top->rdata_ra_o == 0xCAFEBABE);

  std::cout << "[" << main_time
            << "] Reading Addr 10 (Port B). Got: " << std::hex
            << top->rdata_rb_o << " (Expected: 0xDEADBEEF)" << std::endl;
  assert(top->rdata_rb_o == 0xDEADBEEF);

  // --- 测试 3: 读未写入的地址 ---
  std::cout << "--- Test 3: Read unwritten address ---" << std::endl;
  top->addr_ra_i = 1; // 端口 A 读取地址 1 (未写入)
  top->addr_rb_i = 2; // 端口 B 读取地址 2 (未写入)
  top->eval();

  std::cout << "[" << main_time
            << "] Reading Addr 1 (Port A). Got: " << std::hex << top->rdata_ra_o
            << " (Expected: 0x0)" << std::endl;
  assert(top->rdata_ra_o == 0);

  std::cout << "[" << main_time
            << "] Reading Addr 2 (Port B). Got: " << std::hex << top->rdata_rb_o
            << " (Expected: 0x0)" << std::endl;
  assert(top->rdata_rb_o == 0);

  std::cout << "--- [PASSED] All 2R1W SRAM checks passed! ---" << std::endl;

  delete top;
  return 0;
}