#include <common.h>
#include <isa/isa.h>
const char *regs[] = {"$0", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2",
                      "s0", "s1", "a0",  "a1",  "a2", "a3", "a4", "a5",
                      "a6", "a7", "s2",  "s3",  "s4", "s5", "s6", "s7",
                      "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

void isa_reg_display_difftest(cpu_state *cpu, cpu_state *ref) {
  for (int i = 0; i < GPU_NUMBER; i++) {
    printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
           (cpu->gpr[i] == ref->gpr[i]) ? ANSI_FG_GREEN : ANSI_FG_RED, regs[i],
           cpu->gpr[i], ref->gpr[i]);
  }
  printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
         (ref->csr.mcause == cpu->csr.mcause) ? ANSI_FG_GREEN : ANSI_FG_RED,
         "mcause", cpu->csr.mcause, ref->csr.mcause);
  printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
         (ref->csr.mtvec == cpu->csr.mtvec) ? ANSI_FG_GREEN : ANSI_FG_RED,
         "mtvec", cpu->csr.mtvec, ref->csr.mtvec);
  printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
         (cpu->csr.mstatus == ref->csr.mstatus) ? ANSI_FG_GREEN : ANSI_FG_RED,
         "mstatus", cpu->csr.mstatus, ref->csr.mstatus);
  printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
         (cpu->csr.mepc == ref->csr.mepc) ? ANSI_FG_GREEN : ANSI_FG_RED, "mepc",
         cpu->csr.mepc, ref->csr.mepc);
  printf("%s%-4s cur: " FMT_WORD " ref: " FMT_WORD ANSI_NONE "\n",
         (cpu->pc == ref->pc) ? ANSI_FG_GREEN : ANSI_FG_RED, "pc", cpu->pc,
         ref->pc);
}

void isa_reg_display(cpu_state *cpu) {
  for (int i = 0; i < GPU_NUMBER; i++) {
    printf("%s值为%u\n", regs[i], cpu->gpr[i]);
  }
  printf("pc值为%u\n", cpu->pc);
  Log("展示所有寄存器");
}

word_t isa_reg_str2val(const char *s, bool *success) {
  // int reg_number = 32;
  // for(int i = 0; i < reg_number; i ++) {
  //   if(strcmp(s, regs[i]) == 0) {
  //     return cpu.gpr[i];
  //   }
  // }
  // if(strcmp(s, "pc") == 0) {
  //   return cpu.pc;
  // }
  // //提示
  // Log("%s不是寄存器\n",s);
  // assert(0);
  Log("返回寄存器的值");
  return 0;
}