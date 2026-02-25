#include "Vtb_privilege_csr.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kCsrRw = 0u;
constexpr uint32_t kCsrRs = 1u;

constexpr uint32_t kMstatus = 0x300u;
constexpr uint32_t kMedeleg = 0x302u;
constexpr uint32_t kMideleg = 0x303u;
constexpr uint32_t kMtvec = 0x305u;
constexpr uint32_t kMepc = 0x341u;

constexpr uint32_t kSstatus = 0x100u;
constexpr uint32_t kSie = 0x104u;
constexpr uint32_t kStvec = 0x105u;
constexpr uint32_t kSepc = 0x141u;
constexpr uint32_t kScause = 0x142u;
constexpr uint32_t kStval = 0x143u;
constexpr uint32_t kSip = 0x144u;

constexpr uint32_t kEcallFromS = 9u;

struct Resp {
  uint32_t data = 0;
  bool exception = false;
  uint32_t ecause = 0;
  bool mispred = false;
  uint32_t redirect = 0;
};

void tick(Vtb_privilege_csr &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
}

void clear_inputs(Vtb_privilege_csr &top) {
  top.valid_i = 0;
  top.is_csr_i = 0;
  top.is_ecall_i = 0;
  top.is_ebreak_i = 0;
  top.is_mret_i = 0;
  top.is_sret_i = 0;
  top.is_wfi_i = 0;
  top.uop_pc_i = 0;
  top.csr_addr_i = 0;
  top.csr_op_i = 0;
  top.rs1_idx_i = 0;
  top.rs1_data_i = 0;
  top.rob_tag_i = 0;
}

Resp issue(Vtb_privilege_csr &top) {
  top.eval();
  Resp r;
  r.data = top.wb_data_o;
  r.exception = top.wb_exception_o;
  r.ecause = top.wb_ecause_o;
  r.mispred = top.wb_is_mispred_o;
  r.redirect = top.wb_redirect_pc_o;
  tick(top);
  clear_inputs(top);
  tick(top);
  return r;
}

Resp csr_write(Vtb_privilege_csr &top, uint32_t csr, uint32_t val) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_csr_i = 1;
  top.csr_addr_i = csr;
  top.csr_op_i = kCsrRw;
  top.rs1_idx_i = 1;
  top.rs1_data_i = val;
  return issue(top);
}

Resp csr_read(Vtb_privilege_csr &top, uint32_t csr) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_csr_i = 1;
  top.csr_addr_i = csr;
  top.csr_op_i = kCsrRs;
  top.rs1_idx_i = 0;
  top.rs1_data_i = 0;
  return issue(top);
}

Resp sys_mret(Vtb_privilege_csr &top) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_mret_i = 1;
  return issue(top);
}

Resp sys_sret(Vtb_privilege_csr &top) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_sret_i = 1;
  return issue(top);
}

Resp sys_ecall(Vtb_privilege_csr &top, uint32_t pc) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_ecall_i = 1;
  top.uop_pc_i = pc;
  return issue(top);
}

void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cerr << "[FAIL] " << msg << "\n";
    std::exit(1);
  }
}

void expect_csr_rw(Vtb_privilege_csr &top, uint32_t addr, uint32_t value, const char *name) {
  Resp w = csr_write(top, addr, value);
  expect(!w.exception, "csr write should not trap");
  Resp r = csr_read(top, addr);
  expect(!r.exception, "csr read should not trap");
  if (r.data != value) {
    std::cerr << "[FAIL] " << name << " mismatch: got=0x" << std::hex << r.data
              << " expected=0x" << value << std::dec << "\n";
    std::exit(1);
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_privilege_csr top;

  clear_inputs(top);
  top.rst_ni = 0;
  tick(top);
  top.rst_ni = 1;
  tick(top);

  expect_csr_rw(top, kSstatus, 0x00000122u, "sstatus");
  expect_csr_rw(top, kStvec, 0x80000200u, "stvec");
  expect_csr_rw(top, kSepc, 0x80003000u, "sepc");
  expect_csr_rw(top, kScause, 0x00000009u, "scause");
  expect_csr_rw(top, kStval, 0x12345678u, "stval");
  expect_csr_rw(top, kSie, 0x00000222u, "sie");
  expect_csr_rw(top, kSip, 0x00000222u, "sip");
  expect_csr_rw(top, kMedeleg, (1u << kEcallFromS), "medeleg");
  expect_csr_rw(top, kMideleg, (1u << 7), "mideleg");

  // Enter S-mode via mret with MPP=S.
  expect_csr_rw(top, kMtvec, 0x80000100u, "mtvec");
  expect_csr_rw(top, kMepc, 0x80001000u, "mepc");
  expect_csr_rw(top, kMstatus, (1u << 11), "mstatus.mpp=s");
  Resp mret = sys_mret(top);
  expect(!mret.exception, "mret should not trap");
  expect(mret.mispred, "mret should redirect");
  expect(mret.redirect == 0x80001000u, "mret redirect must target mepc");

  // In S-mode, delegated ECALL should trap to STVEC and record SEPC/SCAUSE.
  Resp ecall = sys_ecall(top, 0x80005554u);
  expect(ecall.exception, "ecall should raise exception");
  expect(ecall.ecause == kEcallFromS, "ecall cause should be ECALL_FROM_S");
  expect(ecall.redirect == 0x80000200u, "delegated ecall should redirect to stvec");

  Resp scause = csr_read(top, kScause);
  expect(!scause.exception, "scause read should not trap");
  expect(scause.data == kEcallFromS, "scause should record delegated ecall");

  Resp sepc = csr_read(top, kSepc);
  expect(!sepc.exception, "sepc read should not trap");
  expect(sepc.data == 0x80005554u, "sepc should record delegated ecall pc");

  // sret should be legal in S-mode and return through sepc.
  expect_csr_rw(top, kSepc, 0x80004444u, "sepc.for.sret");
  Resp sret = sys_sret(top);
  expect(!sret.exception, "sret should not trap in s-mode");
  expect(sret.mispred, "sret should redirect");
  expect(sret.redirect == 0x80004444u, "sret redirect must target sepc");

  std::cout << "[PASS] test_privilege_csr" << std::endl;
  return 0;
}
