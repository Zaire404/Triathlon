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

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vtb_sv32_mmu top;

  top.rst_ni = 0;
  top.req_valid_i = 0;
  top.req_vaddr_i = 0;
  top.req_access_i = 0;
  top.satp_i = 0;
  top.pte_req_ready_i = 1;
  top.pte_rsp_valid_i = 0;
  top.pte_rsp_data_i = 0;
  tick(top);
  top.rst_ni = 1;
  tick(top);

  // Case 1: two-level walk translates VA -> PA
  top.req_valid_i = 1;
  top.req_vaddr_i = kVa;
  top.req_access_i = 1;  // load
  top.satp_i = kSatp;
  tick(top);

  expect(top.pte_req_valid_o, "walk should issue level-1 pte request");
  expect(top.pte_req_paddr_o == (kRootBase + (kVpn1 << 2)), "level-1 pte address mismatch");

  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = kPtrPte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);

  expect(top.pte_req_valid_o, "walk should issue level-0 pte request");
  expect(top.pte_req_paddr_o == (kL1Base + (kVpn0 << 2)), "level-0 pte address mismatch");

  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = kLeafPte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);

  expect(top.resp_valid_o, "translate response should be valid");
  expect(!top.resp_page_fault_o, "valid leaf pte should not fault");
  expect(top.resp_paddr_o == ((kLeafPpn << 12) | kPageOff), "translated PA mismatch");

  // Case 2: invalid leaf pte triggers page fault
  top.req_valid_i = 1;
  top.req_vaddr_i = kVa;
  top.req_access_i = 1;
  top.satp_i = kSatp;
  tick(top);
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = kPtrPte;
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);
  top.pte_rsp_valid_i = 1;
  top.pte_rsp_data_i = 0;  // invalid
  tick(top);
  top.pte_rsp_valid_i = 0;
  tick(top);

  expect(top.resp_valid_o, "fault response should be valid");
  expect(top.resp_page_fault_o, "invalid pte should trigger page fault");

  std::cout << "[PASS] test_sv32_mmu" << std::endl;
  return 0;
}
