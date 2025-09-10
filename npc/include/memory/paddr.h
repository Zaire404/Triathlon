#ifndef __MEMORY_PADDR_H__
#define __MEMORY_PADDR_H__
#include <common.h>

/* convert the guest physical address in the guest program to host virtual
 * address in npc */
uint8_t* guest_to_host(paddr_t paddr);
/* convert the host virtual address in npc to guest physical address in the
 * guest program */
paddr_t host_to_guest(uint8_t* haddr);

static inline bool in_pmem(paddr_t addr) {
  return addr - MBASE < MSIZE && addr - MBASE >= 0;
}

word_t paddr_read(paddr_t addr, int len);
void paddr_write(paddr_t addr, int len, word_t data);
#endif