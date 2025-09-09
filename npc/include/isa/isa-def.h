#ifndef __ISA_RISCV_H__
#define __ISA_RISCV_H__
#include <common.h>
typedef struct {
  word_t mtvec;
  word_t mepc;
  word_t mstatus;
  word_t mcause;
} CSRS;

typedef struct {
  word_t gpr[GPU_NUMBER];
  vaddr_t pc;
  CSRS csr;
} cpu_state;
#endif