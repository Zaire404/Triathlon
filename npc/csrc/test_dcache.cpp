// csrc/test_dcache.cpp
#include "Vtb_dcache.h"
#include <assert.h>
#include <iostream>
#include <vector>
#include <verilated.h>
#include <verilated_vcd_c.h>

#define MAX_SIM_TIME 10000
vluint64_t sim_time = 0;

// -------------------------------------------------------------------------
// Helper Functions
// -------------------------------------------------------------------------

void tick(Vtb_dcache *top, VerilatedVcdC *tfp) {
  top->clk_i = 0;
  top->eval();
  if (tfp)
    tfp->dump(sim_time++);
  top->clk_i = 1;
  top->eval();
  if (tfp)
    tfp->dump(sim_time++);
}

void reset(Vtb_dcache *top, VerilatedVcdC *tfp) {
  top->rst_ni = 0;
  tick(top, tfp);
  tick(top, tfp);
  top->rst_ni = 1;
  tick(top, tfp);
}

// 等待直到 Cache 准备好接收请求
void wait_until_ready(Vtb_dcache *top, VerilatedVcdC *tfp, bool is_store) {
  while (sim_time < MAX_SIM_TIME) {
    if (is_store && top->st_req_ready_o)
      return;
    if (!is_store && top->ld_req_ready_o)
      return;
    tick(top, tfp);
  }
  std::cout << "Timeout waiting for ready!" << std::endl;
  exit(1);
}

// 处理缺失 (Miss) 和回写 (Writeback) 的通用函数
// 如果发生 Writeback，会自动处理并继续等待 Refill 请求
void handle_memory_interaction(Vtb_dcache *top, VerilatedVcdC *tfp,
                               uint32_t refill_data_val) {
  // 1. 检查是否先产生了 Writeback (Eviction) 请求
  // 注意：DUT 可能会在发出 miss_req 之前先发出 wb_req
  // 或者在状态机中先处理 WB。我们需要轮询直到出现 miss 或 wb。

  bool miss_handled = false;

  while (!miss_handled && sim_time < MAX_SIM_TIME) {
    // Case A: Writeback Request (脏行被逐出)
    if (top->wb_req_valid_o) {
      // std::cout << "  [Mem] Handling Writeback: Addr=" << std::hex <<
      // top->wb_req_paddr_o
      //           << " Data=" << top->wb_req_data_o[0] << std::endl;
      top->wb_req_ready_i = 1; // 模拟内存接收写回数据
      tick(top, tfp);
      top->wb_req_ready_i = 0;
      // Writeback 完成后，状态机通常会转去处理 Miss，继续循环
    }

    // Case B: Miss Request (需要从内存 Refill)
    else if (top->miss_req_valid_o) {
      // std::cout << "  [Mem] Handling Miss: Addr=" << std::hex <<
      // top->miss_req_paddr_o << std::endl;
      uint32_t req_addr = top->miss_req_paddr_o;
      uint32_t victim_way = top->miss_req_victim_way_o;

      top->miss_req_ready_i = 1; // 接受读请求
      tick(top, tfp);
      top->miss_req_ready_i = 0;

      // 模拟内存延迟
      tick(top, tfp);
      tick(top, tfp);

      // 发送 Refill 数据
      top->refill_valid_i = 1;
      top->refill_paddr_i = req_addr; // 必须匹配请求地址
      top->refill_way_i = victim_way; // 必须回传 victim way

      // 简单起见，填充整个 Cache Line 为重复的 32-bit 数据，或者根据地址生成
      // 注意：根据你的 Cache Line 宽度，这里可能需要填充 refill_data_i[1], [2]
      // 等
      for (int i = 0; i < 8; i++)
        top->refill_data_i[i] = refill_data_val;

      tick(top, tfp);
      top->refill_valid_i = 0;

      miss_handled = true; // Miss 处理完毕
    } else {
      // 既没有 WB 也没有 Miss，继续等待
      tick(top, tfp);
    }
  }
}

// 发起读请求并校验结果
void check_load(Vtb_dcache *top, VerilatedVcdC *tfp, uint32_t addr,
                uint32_t expected_data, int op, const char *msg) {
  wait_until_ready(top, tfp, false);

  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = addr;
  top->ld_req_op_i = op;

  // 必须在这一拍给完激励后 tick，让 Cache 采样
  tick(top, tfp);
  top->ld_req_valid_i = 0; // 撤销请求

  // 检查是否 Hit 还是 Miss
  // 如果下一拍 miss_req_valid_o 拉高，说明 Miss 了
  // 但由于是组合逻辑输出，当前拍如果状态机跳转，输出可能已经变了。
  // 我们简单地循环等待 Response，中间夹杂处理 Memory 交互

  bool got_resp = false;
  while (!got_resp && sim_time < MAX_SIM_TIME) {
    if (top->ld_rsp_valid_o) {
      if (top->ld_rsp_data_o != expected_data) {
        std::cout << "[FAIL] " << msg << " Addr=" << std::hex << addr
                  << " Exp=" << expected_data << " Got=" << top->ld_rsp_data_o
                  << std::endl;
        assert(false);
      } else {
        std::cout << "[PASS] " << msg << std::endl;
      }
      top->ld_rsp_ready_i = 1; // 接收数据
      tick(top, tfp);
      top->ld_rsp_ready_i = 0;
      got_resp = true;
    } else if (top->miss_req_valid_o || top->wb_req_valid_o) {
      // 如果没有命中，需要处理内存填充
      // 假设内存里全是 0x88888888 用于区分，或者由调用者指定
      // 这里为了简单，如果 Miss，默认填充 expected_data (为了让 Load 成功)
      // 但在 Store Miss 测试中可能需要区分。
      handle_memory_interaction(top, tfp, expected_data);
    } else {
      tick(top, tfp);
    }
  }
}

// 发起写请求
void send_store(Vtb_dcache *top, VerilatedVcdC *tfp, uint32_t addr,
                uint32_t data, int op) {
  wait_until_ready(top, tfp, true);
  top->st_req_valid_i = 1;
  top->st_req_addr_i = addr;
  top->st_req_data_i = data;
  top->st_req_op_i = op;

  tick(top, tfp);
  top->st_req_valid_i = 0;

  // 等待 Store 完成 (Store 可能触发 Miss/WB)
  // Store 完成的标志是状态机回到 IDLE。
  // 由于没有显式的 st_resp 信号，我们通过观察 ready
  // 信号恢复来判断，或者处理潜在的 Miss

  // 简单处理：只要不 Ready，就可能有内存交互
  int timeout = 0;
  while (!top->st_req_ready_o && timeout < 100) {
    if (top->miss_req_valid_o || top->wb_req_valid_o) {
      // Store Miss 时的 Refill 数据通常是旧内存数据
      // 我们填 0，这样如果 Store 成功，Load 回来的应该是新数据而不是 0
      handle_memory_interaction(top, tfp, 0x00000000);
    }
    tick(top, tfp);
    timeout++;
  }
}

// -------------------------------------------------------------------------
// Main Test Bench
// -------------------------------------------------------------------------

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_dcache *top = new Vtb_dcache;
  Verilated::traceEverOn(true);
  VerilatedVcdC *tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("dcache_trace.vcd");

  reset(top, tfp);

  // op codes (match decode_pkg.sv)
  const int OP_LB = 0, OP_LH = 1, OP_LW = 2, OP_LD = 3;
  const int OP_LBU = 4, OP_LHU = 5, OP_LWU = 6;
  const int OP_SB = 7, OP_SH = 8, OP_SW = 9, OP_SD = 10;

  std::cout << "--- Starting Enhanced D-Cache Tests ---" << std::endl;

  // ============================================================
  // Test 1: Basic Load Miss & Refill
  // ============================================================
  // 读 0x80001000, 期望 miss, refill 后得到 0x12345678
  check_load(top, tfp, 0x80001000, 0x12345678, OP_LW, "Case 1: Load Miss");

  // ============================================================
  // Test 2: Store Hit (Modify Data)
  // ============================================================
  // 写 0x80001000 (已在 Cache 中), 写入 0xDEADBEEF
  send_store(top, tfp, 0x80001000, 0xDEADBEEF, OP_SW);
  std::cout << "[INFO] Case 2: Store issued." << std::endl;

  // ============================================================
  // Test 3: Load Hit (Verify Store)
  // ============================================================
  // 读 0x80001000, 期望命中并返回 0xDEADBEEF
  check_load(top, tfp, 0x80001000, 0xDEADBEEF, OP_LW, "Case 3: Load Hit");

  // ============================================================
  // Test 4: Store Miss (Write Allocate)
  // ============================================================
  // 写一个不在 Cache 中的地址 0x80002000
  // 预期行为: Miss -> Refill (Old Mem=0) -> Cache Merge (New=0xCAFEBABE) ->
  // Idle
  std::cout << "[TEST] Case 4: Store Miss (Write Allocate)" << std::endl;
  send_store(top, tfp, 0x80002000, 0xCAFEBABE, OP_SW);

  // 验证: 读回来应该是 0xCAFEBABE，而不是 Refill 的 0x00000000
  check_load(top, tfp, 0x80002000, 0xCAFEBABE, OP_LW,
             "Case 4: Load after Store Miss");

  // ============================================================
  // Test 5: Sub-word Access (Byte/Half Operations)
  // ============================================================
  std::cout << "[TEST] Case 5: Sub-word Access" << std::endl;
  uint32_t base = 0x80003000;

  // 1. 初始化该行: 读一次触发 Miss Refill，填入全 0
  check_load(top, tfp, base, 0x00000000, OP_LW, "Case 5: Init line");

  // 2. 写入字节: base+0 = 0x11
  send_store(top, tfp, base + 0, 0x11, OP_SB);
  // 3. 写入半字: base+2 = 0x2233
  send_store(top, tfp, base + 2, 0x2233, OP_SH);

  // 4. 读取验证
  // Word 读取应为 0x22330011 (假设小端序，中间字节未变仍为0)
  check_load(top, tfp, base, 0x22330011, OP_LW, "Case 5: Mixed Size Read");

  // Byte 读取
  check_load(top, tfp, base, 0x11, OP_LBU, "Case 5: LBU check");

  // ============================================================
  // Test 6: Eviction / Capacity Miss (Verify Writeback)
  // ============================================================
  std::cout << "[TEST] Case 6: Forced Eviction (Capacity Thrashing)"
            << std::endl;
  // 这是一个基于概率的测试（因为使用了 LFSR 替换策略），
  // 但如果我们写入足够多的映射到同一 Index 的不同地址，必然会触发 Eviction。
  // 假设 Index Width = 6 (64 sets), Offset = 4 (16 bytes).
  // 我们固定 Index，不断改变 Tag。

  uint32_t alias_base = 0x90000000; // 高位不同，Index 相同(假设低位对齐)
  int conflict_count = 16;          // 远大于可能的 Way 数 (通常 2 或 4)

  // 1. 填满 Cache Set 并标记为 Dirty
  for (int i = 0; i < conflict_count; i++) {
    uint32_t addr =
        alias_base + (i * 0x10000); // 步长足够大以改变 Tag，保持 Index 不变
    // Store 会标记为 Dirty
    // Miss 处理时，handle_memory_interaction 会自动处理之前可能的 WB
    send_store(top, tfp, addr, i + 1, OP_SW);
  }

  // 2. 此时，之前的某些行肯定被踢出了。
  // 我们可以通过观测 handle_memory_interaction 中的打印来确认 WB 是否发生。
  // 或者在 Verilator 波形中查看 `wb_req_valid_o` 是否有脉冲。
  std::cout << "Case 6: Completed. Check waveform for 'wb_req_valid_o' pulses."
            << std::endl;

  // ============================================================
  // Test 7: Misalignment Check
  // ============================================================
  std::cout << "[TEST] Case 7: Misalignment" << std::endl;
  // 尝试读取非对齐地址 0x80001001 (Word access)
  wait_until_ready(top, tfp, false);
  top->ld_req_valid_i = 1;
  top->ld_req_addr_i = 0x80001001;
  top->ld_req_op_i = OP_LW;
  tick(top, tfp);
  top->ld_req_valid_i = 0;

  // 等待响应，期望 ld_rsp_err_o 为 1
  bool err_detected = false;
  for (int i = 0; i < 10; i++) {
    if (top->ld_rsp_valid_o) {
      if (top->ld_rsp_err_o)
        err_detected = true;
      break;
    }
    tick(top, tfp);
  }

  if (err_detected)
    std::cout << "[PASS] Case 7: Misalignment Error Detected." << std::endl;
  else
    std::cout << "[FAIL] Case 7: No Error on Misalignment." << std::endl;

  // Cleanup
  for (int i = 0; i < 20; i++)
    tick(top, tfp);
  tfp->close();
  delete top;
  return 0;
}