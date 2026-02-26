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
constexpr uint32_t kSatp = 0x180u;

constexpr uint32_t kEcallFromS = 9u;
constexpr uint32_t kInstPageFault = 12u;
constexpr uint32_t kMstatusSumBit = 18u;
constexpr uint32_t kMstatusMxrBit = 19u;

struct Resp {
  uint32_t data = 0;
  bool exception = false;
  uint32_t ecause = 0;
  bool mispred = false;
  uint32_t redirect = 0;
  bool sfence_flush = false;
  bool irq_trap = false;
  uint32_t irq_cause = 0;
  uint32_t irq_pc = 0;
  uint32_t irq_redirect = 0;
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
  top.is_sfence_vma_i = 0;
  top.uop_pc_i = 0;
  top.csr_addr_i = 0;
  top.csr_op_i = 0;
  top.rs1_idx_i = 0;
  top.rs1_data_i = 0;
  top.rob_tag_i = 0;
  top.async_exception_inject_i = 0;
  top.async_exception_cause_i = 0;
  top.async_exception_tval_i = 0;
  top.trap_pc_i = 0;
}

Resp issue(Vtb_privilege_csr &top) {
  top.eval();
  Resp r;
  r.data = top.wb_data_o;
  r.exception = top.wb_exception_o;
  r.ecause = top.wb_ecause_o;
  r.mispred = top.wb_is_mispred_o;
  r.redirect = top.wb_redirect_pc_o;
  r.sfence_flush = top.sfence_vma_flush_o;
  r.irq_trap = top.irq_trap_o;
  r.irq_cause = top.irq_trap_cause_o;
  r.irq_pc = top.irq_trap_pc_o;
  r.irq_redirect = top.irq_trap_redirect_pc_o;
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

Resp sys_sfence_vma(Vtb_privilege_csr &top) {
  clear_inputs(top);
  top.valid_i = 1;
  top.is_sfence_vma_i = 1;
  top.rs1_idx_i = 0;
  top.rs1_data_i = 0;
  return issue(top);
}

Resp inject_async_fault(Vtb_privilege_csr &top, uint32_t cause, uint32_t pc, uint32_t tval) {
  clear_inputs(top);
  top.valid_i = 1;
  top.async_exception_inject_i = 1;
  top.async_exception_cause_i = cause;
  top.async_exception_tval_i = tval;
  top.trap_pc_i = pc;
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
  expect_csr_rw(top, kMedeleg, (1u << kEcallFromS) | (1u << kInstPageFault), "medeleg");
  expect_csr_rw(top, kMideleg, (1u << 7), "mideleg");
  expect_csr_rw(top, kSatp, 0x80000000u, "satp");

  // SSTATUS should expose SUM/MXR bits.
  const uint32_t sum_mxr_bits = (1u << kMstatusSumBit) | (1u << kMstatusMxrBit);
  expect_csr_rw(top, kSstatus, sum_mxr_bits, "sstatus.sum_mxr");

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

  // Async instruction page fault should trap to STVEC and write SEPC/SCAUSE/STVAL.
  const uint32_t fault_pc = 0x80400000u;
  Resp pf = inject_async_fault(top, kInstPageFault, fault_pc, fault_pc);
  expect(pf.irq_trap, "async page fault should raise irq_trap sideband");
  expect(pf.irq_cause == kInstPageFault, "async page fault cause should be 12");
  expect(pf.irq_pc == fault_pc, "async page fault pc sideband mismatch");
  expect(pf.irq_redirect == 0x80000200u, "async page fault should redirect to stvec");

  Resp scause_pf = csr_read(top, kScause);
  expect(!scause_pf.exception, "scause read after async fault should not trap");
  expect(scause_pf.data == kInstPageFault, "scause should record instruction page fault");

  Resp sepc_pf = csr_read(top, kSepc);
  expect(!sepc_pf.exception, "sepc read after async fault should not trap");
  expect(sepc_pf.data == fault_pc, "sepc should record fault pc");

  Resp stval_pf = csr_read(top, kStval);
  expect(!stval_pf.exception, "stval read after async fault should not trap");
  expect(stval_pf.data == fault_pc, "stval should record faulting vaddr");

  // sret should be legal in S-mode and return through sepc.
  expect_csr_rw(top, kSepc, 0x80004444u, "sepc.for.sret");
  Resp sret = sys_sret(top);
  expect(!sret.exception, "sret should not trap in s-mode");
  expect(sret.mispred, "sret should redirect");
  expect(sret.redirect == 0x80004444u, "sret redirect must target sepc");

  // sfence.vma should be legal in S-mode and trigger local flush pulse.
  Resp sfence = sys_sfence_vma(top);
  expect(!sfence.exception, "sfence.vma should not trap in s-mode");
  expect(sfence.sfence_flush, "sfence.vma should generate flush pulse");

  std::cout << "[PASS] test_privilege_csr" << std::endl;
  return 0;
}
