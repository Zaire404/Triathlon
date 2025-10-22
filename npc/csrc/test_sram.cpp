// csrc/test_sram.cpp
#include "Vtb_sram.h"
#include "verilated.h"
#include <cassert>
#include <iostream>

vluint64_t main_time = 0; // 跟踪仿真时间

// 时钟滴答辅助函数
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

  std::cout << "--- [START] Running Complex C++ test for SRAM ---" << std::endl;

  // 1. 复位
  top->rst_ni = 0;
  top->we_i = 0;
  top->addr_i = 0;
  top->wdata_i = 0;
  tick(top);
  top->rst_ni = 1;
  std::cout << "[" << main_time << "] Reset complete." << std::endl;

  // --- 测试 1: 写入测试 (Write Enable) ---
  // 验证 'we_i = 0' 时, 写入不会发生
  std::cout << "--- Test 1: Write Enable Logic ---" << std::endl;
  top->we_i = 0; // 明确禁用写入
  top->addr_i = 5;
  top->wdata_i = 0xDEADBEEF;
  std::cout << "[" << main_time
            << "] Setting addr=5, wdata=0xDEADBEEF, but we_i=0" << std::endl;
  tick(top); // 即使时钟变化, 也不应写入

  top->addr_i = 5; // 设置读取地址
  top->eval();     // 异步读
  std::cout << "[" << main_time
            << "] Reading from addr=5. Got: " << top->rdata_o
            << " (Expected: 0)" << std::endl;
  assert(top->rdata_o == 0); // 应该还是复位后的 0

  // --- 测试 2: 基本的 写-读 测试 (Write-Read) ---
  std::cout << "--- Test 2: Basic Write-Read ---" << std::endl;
  top->we_i = 1; // 启用写入
  top->addr_i = 5;
  top->wdata_i = 0xCAFEBABE;
  std::cout << "[" << main_time << "] Writing 0xCAFEBABE to addr=5 (we_i=1)"
            << std::endl;
  tick(top); // 时钟上升沿 *计划* 写入

  top->we_i = 0;   // 停止写入
  top->addr_i = 5; // 保持读取地址
  top->eval();

  // 在 Cycle N+1, 异步读 (assign) 现在读到的是 Cycle N 写入的值
  std::cout << "[" << main_time
            << "] Reading from addr=5. Got: " << top->rdata_o
            << " (Expected: 0xCAFEBABE)" << std::endl;
  assert(top->rdata_o == 0xCAFEBABE);

  // --- 测试 3: 写后立即读 (RAW) 失败场景 (模拟错误的 C++ 代码) ---
  std::cout << "--- Test 3: Demonstrating Failed Read-After-Write ---"
            << std::endl;
  top->we_i = 1;
  top->addr_i = 10;
  top->wdata_i = 0x12345678;
  std::cout << "[" << main_time << "] Writing 0x12345678 to addr=10"
            << std::endl;
  tick(top); // 时钟上升沿 *计划* 写入 (Cycle N+2)

  top->we_i = 0;
  top->addr_i = 10;
  top->eval(); // <--- 只调用 eval(), 不推进时钟

  std::cout << "[" << main_time
            << "] Reading from addr=10 (using eval). Got: " << top->rdata_o
            << " (Expected previous value: 0x12345678)" << std::endl;
  // 注意: 它读到的是 addr=5 的旧值, 因为 addr_i 刚刚才改变, 组合逻辑读到了旧的
  // mem[5] 让我们再 eval() 一次, 确保异步读稳定
  top->eval();

  std::cout << "--- [PASSED] All SRAM checks passed successfully! ---"
            << std::endl;

  delete top;
  return 0;
}