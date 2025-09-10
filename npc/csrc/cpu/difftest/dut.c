#include <common.h>
#include <dlfcn.h>
#include <isa/isa.h>
#include <memory/paddr.h>
void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n,
                            bool direction) = NULL;
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void isa_reg_display_difftest(cpu_state *cpu, cpu_state *ref);

static int is_skip_ref = 0;
static int num = 0;
void difftest_skip_ref() {
  if (is_skip_ref == 1) {
    num++;
  } else {
    is_skip_ref = 2;
    num = 1;
  }
}

void init_difftest(char *ref_so_file, long img_size, int port) {
  assert(ref_so_file != NULL);

  void *handle;
  handle = dlopen(ref_so_file, RTLD_LAZY);
  assert(handle);

  ref_difftest_memcpy =
      (void (*)(paddr_t, void *, size_t, bool))dlsym(handle, "difftest_memcpy");
  assert(ref_difftest_memcpy);
  ref_difftest_regcpy =
      (void (*)(void *, bool))dlsym(handle, "difftest_regcpy");
  assert(ref_difftest_regcpy);
  ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
  assert(ref_difftest_exec);

  void (*ref_difftest_init)(int) =
      (void (*)(int))dlsym(handle, "difftest_init");
  assert(ref_difftest_init);

  Log("Differential testing: %s", ANSI_FMT("ON", ANSI_FG_GREEN));
  Log("The result of every instruction will be compared with %s. "
      "This will help you a lot for debugging, but also significantly reduce "
      "the performance. "
      "If it is not necessary, you can turn it off in menuconfig.",
      ref_so_file);

  ref_difftest_init(port);
  ref_difftest_memcpy(MBASE, guest_to_host(MBASE), img_size, DIFFTEST_TO_REF);
  ref_difftest_regcpy(&CPU, DIFFTEST_TO_REF);
}

bool isa_difftest_checkregs(cpu_state *ref_r, vaddr_t pc) {
  bool ok = 1;
  for (int i = 0; i < GPU_NUMBER; i++) {
    if (CPU.gpr[i] != ref_r->gpr[i]) {
      ok = 0;
    }
  }
  if (ref_r->pc != CPU.pc) {
    ok = 0;
  }
  if (ref_r->csr.mcause != CPU.csr.mcause) {
    ok = 0;
  }
  if (ref_r->csr.mepc != CPU.csr.mepc) {
    ok = 0;
  }
  if (ref_r->csr.mstatus != CPU.csr.mstatus) {
    ok = 0;
  }
  if (ref_r->csr.mtvec != CPU.csr.mtvec) {
    ok = 0;
  }
  return ok;
}

static void checkregs(cpu_state *ref, vaddr_t pc) {
  if (!isa_difftest_checkregs(ref, pc)) {
    nemu_state.state = NEMU_ABORT;
    nemu_state.halt_pc = pc;
    isa_reg_display_difftest(&CPU, ref);
  }
}

void difftest_step(vaddr_t pc) {
  cpu_state ref_r;
  // 这里的逻辑是
  // 因为DUT拿到新的指令的时候，会直接访问内存
  // 导致比ref多了一个周期
  // 所以只需要多延迟一个周期即可

  if (is_skip_ref == 1 && num) {
    ref_difftest_regcpy(&CPU, DIFFTEST_TO_REF);
    num--;
    return;
  }
  if (is_skip_ref == 2 || (is_skip_ref == 1 && num == 0)) is_skip_ref--;
  ref_difftest_exec(1);
  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
  if (nemu_state.state == NEMU_END) {
    return;
  }
  checkregs(&ref_r, pc);
}