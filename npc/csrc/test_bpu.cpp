#include "Vtb_BPU.h"     // 包含 Verilator 生成的模块头文件
#include "verilated.h"
#include "verilated_vcd_c.h" // <--- 1. 包含 VCD 波形头文件
#include <cassert>
#include <iostream>

vluint64_t sim_time = 0; // 用于波形文件的时间戳

// 辅助函数：驱动一个时钟周期 (0 -> 1 -> 0)
// 并在每个边沿调用 eval() 和 dump()
void tick(Vtb_BPU *top, VerilatedVcdC *tfp) {
  // --- 下降沿 ---
  top->i_clk = 0;
  top->eval(); // 评估
  if (tfp) tfp->dump(sim_time++); // 转储波形

  // --- 上升沿 ---
  top->i_clk = 1;
  top->eval(); // 评估 (时序逻辑在这里触发)
  if (tfp) tfp->dump(sim_time++); // 转储波形
}

// 辅助函数：仅复位
void reset(Vtb_BPU *top, VerilatedVcdC *tfp) {
  top->i_rst = 1; 
  tick(top, tfp); 
  tick(top, tfp); 
  top->i_rst = 0; 
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  Vtb_BPU *top = new Vtb_BPU;
  VerilatedVcdC *tfp = new VerilatedVcdC; // <--- 3. 创建 VCD 对象

  // 初始化波形追踪
  top->trace(tfp, 99);        // 链接 VCD 对象到 top 模块 (99是追踪深度)
  tfp->open("waveform.vcd");  // <--- 4. 打开波形文件

  reset(top, tfp); // 执行复位
  
  tfp->close();
  delete tfp;
  delete top;
  printf("end\n");
  return 0;
}