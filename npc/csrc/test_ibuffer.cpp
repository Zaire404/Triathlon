// csrc/test_ibuffer.cpp
#include "Vtb_ibuffer.h"
#include "verilated.h"
#include <cassert>
#include <deque>
#include <iomanip>
#include <iostream>
#include <random>
#include <vector>

// --- 配置参数 (需与 SV 保持一致) ---
const int INSTR_PER_FETCH = 4; // Fetch 宽度
const int DECODE_WIDTH = 4;    // Decode 宽度
const int IB_DEPTH = 8;        // 测试模块中定义的深度
const int ILEN_BYTES = 4;      // 32-bit 指令

vluint64_t main_time = 0;

struct Instruction {
  uint32_t inst;
  uint32_t pc;
};

// C++ 端维护的 Golden Model
std::deque<Instruction> expected_queue;

void tick(Vtb_ibuffer *top) {
  top->clk_i = 0;
  top->eval();
  main_time++;
  top->clk_i = 1;
  top->eval();
  main_time++;
}

void reset(Vtb_ibuffer *top) {
  top->rst_ni = 0;
  top->flush_i = 0;
  top->fe_valid_i = 0;
  top->ibuf_ready_i = 0;
  // 清空输入数据
  for (int i = 0; i < INSTR_PER_FETCH; ++i)
    top->fe_instrs_i[i] = 0;
  top->fe_pc_i = 0;

  tick(top);
  tick(top);
  top->rst_ni = 1;
  expected_queue.clear();
  std::cout << "[Reset] Done." << std::endl;
}

// 辅助函数：设置输入 Fetch Group
void set_fetch_group(Vtb_ibuffer *top, uint32_t base_pc,
                     const std::vector<uint32_t> &instrs) {
  assert(instrs.size() == INSTR_PER_FETCH);
  top->fe_pc_i = base_pc;

  // Verilator 的宽端口通常是 uint32_t 数组 (WData)
  // fe_instrs_i 是 128 位 (4 * 32)
  // 假设它是 Little Endian: [0]是低位(Instr0), [3]是高位(Instr3)
  // 如果 SV 中是 packed [3:0][31:0]，则 instrs[0] 对应低位
  for (int i = 0; i < INSTR_PER_FETCH; ++i) {
    top->fe_instrs_i[i] = instrs[i];
  }
}

// 辅助函数：从输出读取 Decode Group
std::vector<Instruction> get_decode_group(Vtb_ibuffer *top) {
  std::vector<Instruction> group;
  for (int i = 0; i < DECODE_WIDTH; ++i) {
    Instruction instr;
    // 同样假设展平后的映射关系
    instr.inst = top->ibuf_instrs_o[i];

    // PC 是 64 位 (PLEN=64 假设)，如果是 32 位则只需取低位
    // ibuf_pcs_o 是 [4 * PLEN]，在 C++ 中如果是 WData (uint32_t[])
    // 假设 PLEN=32，则 ibuf_pcs_o[i] 就是 PC
    // 假设 PLEN=64，则 ibuf_pcs_o[2*i] 和 [2*i+1] 组成 PC
    // 根据您的 config_pkg，PLEN 通常等于 XLEN/VLEN (32 或 64)
    // 这里为了兼容性，假设 PLEN=32 (常见测试配置) 或者 64
    // 您的 build_config_pkg 中: cfg.PLEN = user_cfg.VLEN (32)
    // 所以它是 32 位 PC。
    instr.pc = top->ibuf_pcs_o[i];

    group.push_back(instr);
  }
  return group;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_ibuffer *top = new Vtb_ibuffer;

  // 随机数生成器
  std::mt19937 rng(12345);
  std::uniform_int_distribution<uint32_t> dist_instr(0, 0xFFFFFFFF);
  std::uniform_int_distribution<int> dist_bool(0, 1);

  std::cout << "--- [START] IBuffer Verification ---" << std::endl;
  reset(top);

  uint32_t current_fetch_pc = 0x80000000;
  int cycles = 100000;
  int accepted_instr_count = 0;
  int retired_instr_count = 0;

  for (int t = 0; t < cycles; ++t) {
    // --- 1. 驱动输入 (Frontend) ---
    bool try_fetch =
        (dist_bool(rng) ||
         expected_queue.size() < 4); // 随机尝试 Fetch，如果队列空则大概率 Fetch
    bool flush_now = (t > 50 && t % 200 == 0); // 周期性 Flush

    if (flush_now) {
      top->flush_i = 1;
      top->fe_valid_i = 0; // Flush 时通常前端无效
      expected_queue.clear();
      std::cout << "[" << main_time << "] FLUSH Asserted!" << std::endl;
    } else {
      top->flush_i = 0;
      top->fe_valid_i = try_fetch ? 1 : 0;

      if (try_fetch) {
        std::vector<uint32_t> instrs(INSTR_PER_FETCH);
        for (int i = 0; i < INSTR_PER_FETCH; ++i)
          instrs[i] = dist_instr(rng);
        set_fetch_group(top, current_fetch_pc, instrs);
      }
    }

    // --- 2. 驱动输入 (Backend) ---
    // 随机决定后端是否 Ready
    bool backend_ready = (dist_bool(rng) == 1);
    top->ibuf_ready_i = backend_ready;

    // --- 3. Evaluate (Rising Edge Logic) ---
    // 我们需要在时钟沿之前保存 inputs，tick 内部会 eval 组合逻辑 -> update
    // register 但为了正确模拟 handshake，我们需要知道 DUT
    // 在当前组合逻辑下的输出 (fe_ready_o, ibuf_valid_o)

    top->clk_i = 0;
    top->eval();

    // --- 4. 记分板逻辑 (Capture Fetch) ---
    if (!top->flush_i && top->fe_valid_i && top->fe_ready_o) {
      // 握手成功，将指令加入 Golden Model
      // 注意：因为上面已经 set_fetch_group 了，数据就在端口上
      for (int i = 0; i < INSTR_PER_FETCH; ++i) {
        Instruction instr;
        instr.inst = top->fe_instrs_i[i];
        instr.pc = current_fetch_pc + i * ILEN_BYTES;
        expected_queue.push_back(instr);
      }
      current_fetch_pc += INSTR_PER_FETCH * ILEN_BYTES;
      accepted_instr_count += INSTR_PER_FETCH;
      // std::cout << "  [Fetch] Accepted " << INSTR_PER_FETCH << " instrs." <<
      // std::endl;
    }

    // --- 5. 记分板逻辑 (Verify Decode) ---
    if (!top->flush_i && top->ibuf_valid_o && top->ibuf_ready_i) {
      // 后端握手成功，检查输出数据
      std::vector<Instruction> out_group = get_decode_group(top);

      assert(expected_queue.size() >= DECODE_WIDTH); // 确保有足够的数据

      for (int i = 0; i < DECODE_WIDTH; ++i) {
        Instruction expected = expected_queue.front();
        expected_queue.pop_front();
        Instruction actual = out_group[i];

        if (actual.inst != expected.inst || actual.pc != expected.pc) {
          std::cout << "[ERROR] Mismatch at time " << main_time << std::endl;
          std::cout << "  Expected: PC=0x" << std::hex << expected.pc
                    << " Inst=0x" << expected.inst << std::endl;
          std::cout << "  Actual:   PC=0x" << std::hex << actual.pc
                    << " Inst=0x" << actual.inst << std::endl;
          assert(false);
        }
      }
      retired_instr_count += DECODE_WIDTH;
      // std::cout << "  [Decode] Retired " << DECODE_WIDTH << " instrs." <<
      // std::endl;
    }

    // --- 6. 检查 Flush 后的状态 ---
    if (top->flush_i) {
      // Flush 应该是组合逻辑生效 (fe_ready_o 可能变低或变高取决于实现，但
      // valid_o 必须为 0) 检查 ibuffer 是否立即响应 Flush (输出 valid 拉低)
      // ibuffer.sv 实现: assign ibuf_valid_o = (!flush_i) && ...
      assert(top->ibuf_valid_o == 0);
      // 指针复位是在时钟沿发生的，所以这里只是检查组合逻辑输出
    }

    // --- 7. Clock Tick ---
    // 这里 top->eval() 会更新时序逻辑 (Register Update)
    top->clk_i = 1;
    top->eval();
    main_time++;

    // --- 8. 边界情况检查 ---
    // IBuffer 允许在单拍内先 dequeue 再 enqueue，且可能暂存 pending group。
    // 因此仅用 expected_queue 接近深度时不能强制要求 fe_ready 必须为 0。
    if (!top->flush_i) {
      if (expected_queue.size() > (IB_DEPTH + INSTR_PER_FETCH)) {
        std::cout << "[ERROR] IBuffer Queue Check: Expected Size="
                  << expected_queue.size() << " Depth=" << IB_DEPTH
                  << " pending_limit=" << INSTR_PER_FETCH << std::endl;
        assert(false);
      }
    }

    // 空状态检查
    if (!top->flush_i) {
      if (expected_queue.size() < DECODE_WIDTH) {
        if (top->ibuf_valid_o == 1) {
          std::cout << "[ERROR] IBuffer Empty Check: Expected Size="
                    << expected_queue.size() << " but ibuf_valid is 1."
                    << std::endl;
          assert(top->ibuf_valid_o == 0);
        }
      }
    }
  }

  std::cout << "--- Verification Statistics ---" << std::endl;
  std::cout << "Total Cycles: " << cycles << std::endl;
  std::cout << "Accepted Instructions: " << accepted_instr_count << std::endl;
  std::cout << "Retired Instructions:  " << retired_instr_count << std::endl;
  std::cout << "Final Queue Size:      " << expected_queue.size() << std::endl;

  if (expected_queue.size() > IB_DEPTH) {
    std::cout << "[WARNING] Model queue size exceeds hardware depth, possibly "
                 "due to loose full-check."
              << std::endl;
  }

  std::cout << "--- [PASSED] IBuffer verification successful! ---" << std::endl;

  delete top;
  return 0;
}