#include <memory/host.h>
#include <memory/paddr.h>
static uint8_t pmem[MSIZE] = {};

uint8_t* guest_to_host(paddr_t paddr) { return pmem + paddr - MBASE; }
paddr_t host_to_guest(uint8_t* haddr) { return haddr - pmem + MBASE; }

static word_t pmem_read(paddr_t addr, int len) {
  word_t ret = host_read(guest_to_host(addr), len);
  return ret;
}

static void pmem_write(paddr_t addr, int len, word_t data) {
  host_write(guest_to_host(addr), len, data);
}

word_t paddr_read(paddr_t addr, int len) {
  if (in_pmem(addr)) {
#if Mtrace
    printf("读地址为%x 长度为%d\n", addr, len);
#endif
    return pmem_read(addr, len);
  }
  return 0;
}

void paddr_write(paddr_t addr, int len, word_t data) {
  if (in_pmem(addr)) {
#if Mtrace
    printf("写地址为%x 长度为%d 数据为%x\n", addr, len, data);
#endif
    pmem_write(addr, len, data);
  }
}