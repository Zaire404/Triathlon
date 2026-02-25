#include "Vtb_sv32_mmu.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

namespace {

constexpr uint32_t kSatpModeSv32 = 0x80000000u;
constexpr uint32_t kRootPpn = 0x00080010u;  // root table at 0x80010000
constexpr uint32_t kSatp = kSatpModeSv32 | kRootPpn;

constexpr uint32_t kVa = 0x40000123u;
constexpr uint32_t kVpn1 = (kVa >> 22) & 0x3ffu;
constexpr uint32_t kVpn0 = (kVa >> 12) & 0x3ffu;
constexpr uint32_t kPageOff = kVa & 0xfffu;

constexpr uint32_t kL1Ppn = 0x00080020u;       // l1 table at 0x80020000
constexpr uint32_t kLeafPpn = 0x00080030u;     // mapped page at 0x80030000
constexpr uint32_t kRootBase = kRootPpn << 12; // physical
constexpr uint32_t kL1Base = kL1Ppn << 12;

constexpr uint32_t kPteV = 1u << 0;
constexpr uint32_t kPteR = 1u << 1;
constexpr uint32_t kPteW = 1u << 2;
constexpr uint32_t kPteX = 1u << 3;
constexpr uint32_t kPteA = 1u << 6;
constexpr uint32_t kPteD = 1u << 7;

constexpr uint32_t kPtrPte = (kL1Ppn << 10) | kPteV;
constexpr uint32_t kLeafPte = (kLeafPpn << 10) | kPteV | kPteR | kPteA | kPteD;
constexpr uint32_t kLeafExecPte = (kLeafPpn << 10) | kPteV | kPteX | kPteA;
constexpr uint32_t kLeafNoWritePte = (kLeafPpn << 10) | kPteV | kPteR | kPteA | kPteD;
constexpr uint32_t kSuperLeafBadPpn0 = ((0x00123456u << 10) | kPteV | kPteR | kPteA | kPteD);

void tick(Vtb_sv32_mmu &top) {
  top.clk_i = 0;
  top.eval();
  top.clk_i = 1;
  top.eval();
}

void expect(bool cond, const char *msg) {
  if (!cond) {
    std::cerr << "[FAIL] " << msg << "\n";
    std::exit(1);
  }
}

void clear_signals(Vtb_sv32_mmu &top) {
  top.req_valid_i = 0;
  top.req_vaddr_i = 0;
  top.req_access_i = 0;
  top.satp_i = 0;
  top.pte_req_ready_i = 1;
  top.pte_rsp_valid_i = 0;
  top.pte_rsp_data_i = 0;
}

void issue_walk(Vtb_sv32_mmu &top, uint32_t vaddr, uint32_t access, uint32_t satp) {
  top.req_valid_i = 1;
  top.req_vaddr_i = vaddr;
  top.req_access_i = access;
  top.satp_i = satp;
  expect(top.req_ready_o, "request should be issued only when req_ready_o=1");
  tick(top);
  top.req_valid_i = 0;
}

void feed_l1_ptr(Vtb_sv32_mmu &top, uint32_t ptr_pte) {
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = ptr_pte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);
}

void feed_l0_leaf(Vtb_sv32_mmu &top, uint32_t leaf_pte) {
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = leaf_pte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_sv32_mmu top;

  top.rst_ni = 0;
  clear_signals(top);
  tick(top);
  top.rst_ni = 1;
  tick(top);

  // Case 1: two-level walk translates VA -> PA
  issue_walk(top, kVa, 1, kSatp);  // load

  expect(top.pte_req_valid_o, "walk should issue level-1 pte request");
  expect(top.pte_req_paddr_o == (kRootBase + (kVpn1 << 2)), "level-1 pte address mismatch");

  feed_l1_ptr(top, kPtrPte);

  expect(top.pte_req_valid_o, "walk should issue level-0 pte request");
  expect(top.pte_req_paddr_o == (kL1Base + (kVpn0 << 2)), "level-0 pte address mismatch");

  feed_l0_leaf(top, kLeafPte);

  expect(top.resp_valid_o, "translate response should be valid");
  expect(!top.resp_page_fault_o, "valid leaf pte should not fault");
  expect(top.resp_paddr_o == ((kLeafPpn << 12) | kPageOff), "translated PA mismatch");

  // Case 2: invalid leaf pte triggers page fault
  issue_walk(top, kVa, 1, kSatp);
  feed_l1_ptr(top, kPtrPte);
  feed_l0_leaf(top, 0);  // invalid

  expect(top.resp_valid_o, "fault response should be valid");
  expect(top.resp_page_fault_o, "invalid pte should trigger page fault");

  // Case 3: satp.mode=0 bypasses page walk and returns direct PA
  issue_walk(top, kVa, 1, 0);
  expect(top.resp_valid_o, "satp.mode=0 should return response");
  expect(!top.resp_page_fault_o, "satp.mode=0 should not fault");
  expect(top.resp_paddr_o == kVa, "satp.mode=0 should bypass to PA=VA");
  expect(!top.pte_req_valid_o, "satp.mode=0 should not request PTE");

  // Case 4: instruction access requires X and A bits
  issue_walk(top, kVa, 0, kSatp);  // instr
  feed_l1_ptr(top, kPtrPte);
  feed_l0_leaf(top, kLeafPte);  // no X bit
  expect(top.resp_valid_o, "instr fault response should be valid");
  expect(top.resp_page_fault_o, "instr access without X should page fault");

  issue_walk(top, kVa, 0, kSatp);  // instr
  feed_l1_ptr(top, kPtrPte);
  feed_l0_leaf(top, kLeafExecPte);
  expect(top.resp_valid_o, "instr executable response should be valid");
  expect(!top.resp_page_fault_o, "instr access with X should pass");

  // Case 5: store access requires R/W/A/D bits
  issue_walk(top, kVa, 2, kSatp);  // store
  feed_l1_ptr(top, kPtrPte);
  feed_l0_leaf(top, kLeafNoWritePte);
  expect(top.resp_valid_o, "store fault response should be valid");
  expect(top.resp_page_fault_o, "store access without W should page fault");

  // Case 6: level-1 superpage leaf requires low PPN zero
  issue_walk(top, kVa, 1, kSatp);
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = kSuperLeafBadPpn0;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);
  expect(top.resp_valid_o, "superpage check response should be valid");
  expect(top.resp_page_fault_o, "superpage with non-zero low PPN should fault");

  // Case 7: response should not depend on req_ready after request is issued
  issue_walk(top, kVa, 1, kSatp);
  top.pte_req_ready_i = 0;
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = kPtrPte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  top.pte_req_ready_i = 1;
  tick(top);
  expect(top.pte_req_valid_o, "l1 response should be accepted even if req_ready later drops");
  expect(top.pte_req_paddr_o == (kL1Base + (kVpn0 << 2)), "l0 pte request should still be issued");

  std::cout << "[PASS] test_sv32_mmu" << std::endl;
  return 0;
}
