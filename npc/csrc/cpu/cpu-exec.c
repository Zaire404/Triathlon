#include <common.h>
#include <isa/isa.h>
#include "cpu/cpu.h"
#include <svdpi.h>
#include "verilated_dpi.h"
#include <memory/vaddr.h>

#if CONFIG_FST_WAVE_TRACE
#include "verilated_vcd_c.h"
VerilatedVcdC *tfp = NULL;
#endif

cpu_state CPU = {};
extern void difftest_step(vaddr_t pc);
// contextp用来保存仿真的时间
VerilatedContext* contextp = NULL;
static Vcpu* cpu;

static void step_and_dump_wave(){
  cpu->eval();
  contextp->timeInc(1);
#if CONFIG_FST_WAVE_TRACE
  tfp->dump(contextp->time());
#endif
}

static void single_cycle() {
    cpu->clk = 0; step_and_dump_wave();
    cpu->clk = 1; step_and_dump_wave();
}

static void reset(int n) {
  cpu->rst = 1;
  while (n -- > 0) single_cycle();
  cpu->rst = 0;
}

void sim_init(){
  contextp = new VerilatedContext;
  cpu = new Vcpu;
#if CONFIG_FST_WAVE_TRACE
  tfp = new VerilatedVcdC;
  contextp->traceEverOn(true);
  cpu->trace(tfp, 0);
  tfp->open("/home/xuxubaobao/Desktop/ysyx-workbench/npc/logs/dump.vcd");
#endif
  reset(RESET_NUMBER);
}

void sim_exit(){
  step_and_dump_wave();
#if CONFIG_FST_WAVE_TRACE
  tfp->close();
#endif
}

char logbuf[128];

#define IRINGBUF_SIZE 16
typedef struct {
    word_t pc;
    char log[128];
} IRingBufEntry;

typedef struct {
    IRingBufEntry entries[IRINGBUF_SIZE];
    int head; // 指向最早的有效条目
    int tail; // 指向下一个写入位置
} IRingBuf;

static IRingBuf iringbuf;
void init_iringbuf() {
  iringbuf.head = 0;
  iringbuf.tail = 0;
}

void disply_iringbuf() {
  for(int i = iringbuf.head; i != iringbuf.tail; i = (i + 1) % IRINGBUF_SIZE) {
    printf("pc:%x:%s\n",iringbuf.entries[i].pc,iringbuf.entries[i].log);
  }
}

void add_iringbuf(int pc, char *p){
  if(((iringbuf.tail + 1) % IRINGBUF_SIZE) == iringbuf.head) //证明已经满了
  iringbuf.head = (iringbuf.head + 1) % IRINGBUF_SIZE; //删除第一个
  char *cur = iringbuf.entries[iringbuf.tail].log;
  iringbuf.entries[iringbuf.tail].pc = pc;
  strcpy(cur, p);
  iringbuf.tail = (iringbuf.tail + 1) % IRINGBUF_SIZE; //指向下一个写入位置
}
void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);

void execute(uint64_t n) {
  for (;n > 0; n --) {
    #if Itrace
    char *p = logbuf;
    p += snprintf(p, sizeof(logbuf), FMT_WORD ":", CPU.pc);
    uint32_t instr = vaddr_ifetch(CPU.pc, 4); 
    p += snprintf(p, 10, " %08x", instr);
    int space_len = 2;
    memset(p, ' ', space_len);
    p += space_len;
    disassemble(p, logbuf + sizeof(logbuf) - p, CPU.pc, (uint8_t *)&instr, 4);
    add_iringbuf(CPU.pc, logbuf);
    printf("%s\n",logbuf);
    #endif
    single_cycle();
    difftest_step(CPU.pc);
    if(nemu_state.state != NEMU_RUNNING) break;
  }
}

extern "C" void ebreak(){ //ebreak指令
  sim_exit();
  nemu_state.state = NEMU_END;
  nemu_state.halt_ret = CPU.gpr[10];
  nemu_state.halt_pc = CPU.pc;
}
// 修正后
extern "C" void cur_pc(int pc){ //获得当前周期的PC值
  CPU.pc = pc;
}
extern "C" void cur_gpu(svOpenArrayHandle var) {
  uint32_t *ptr = (uint32_t *)(((VerilatedDpiOpenVar*)var)->datap());
  for(int i = 0; i < GPU_NUMBER; i ++) {
    CPU.gpr[i] = ptr[i]; //read
  }
}
// 修正后
extern "C" void cur_csr(int mcause, int mstatus, int mtvec, int mepc){
  CPU.csr.mcause = mcause;
  CPU.csr.mstatus = mstatus;
  CPU.csr.mtvec = mtvec;
  CPU.csr.mepc = mepc;
}

void cpu_exec(uint64_t n) {
  switch (nemu_state.state) {
   case NEMU_END: case NEMU_ABORT: case NEMU_QUIT:
      printf("Program execution has ended. To restart the program, exit NEMU and run again.\n");
      return;
    default: nemu_state.state = NEMU_RUNNING;
  }

  execute(n);

  switch (nemu_state.state) {
    case NEMU_RUNNING: nemu_state.state = NEMU_STOP; break;

    case NEMU_END: case NEMU_ABORT:
      Log("nemu: %s at pc = " FMT_WORD,
          (nemu_state.state == NEMU_ABORT ? ANSI_FMT("ABORT", ANSI_FG_RED) :
           (nemu_state.halt_ret == 0 ? ANSI_FMT("HIT GOOD TRAP", ANSI_FG_GREEN) :
            ANSI_FMT("HIT BAD TRAP", ANSI_FG_RED))),
          nemu_state.halt_pc);
      // fall through
    case NEMU_QUIT: break;
  }
}