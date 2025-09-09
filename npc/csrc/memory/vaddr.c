#include <common.h>
#include <memory/paddr.h>
#include <sys/time.h>

void difftest_skip_ref();
word_t vaddr_ifetch(vaddr_t addr, int len) {
  return paddr_read(addr, len);
}

word_t vaddr_read(vaddr_t addr, int len) {
  return paddr_read(addr, len);
}

void vaddr_write(vaddr_t addr, int len, word_t data) {
  paddr_write(addr, len, data);
}

extern "C" int fetch_instr(int addr){
  if(addr == 0) return 0; //因为reset的时候pc为0 需要特判一下 别的都不需要
  return vaddr_ifetch(addr, 4);
}

extern "C" void dpi_mem_write (int addr, int data, char wmask){
  if(addr == SERIAL_MMIO) { //如果写的地址是串口地址，就把这个字符串输出
    putchar(data);
    fflush(stdout);
    difftest_skip_ref();
  }
  else {
    switch (wmask){
    case 1:
      paddr_write(addr, 1, data);
      break;
    case 3:
      paddr_write(addr, 2, data);
      break;
    case 15:
      paddr_write(addr, 4, data);
      break;
    }
  }
}

static uint64_t bool_time = 0;

extern "C" int dpi_mem_read (int addr){
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);  // 使用单调时钟
  uint64_t cur_us = ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
  if(addr == RTC_ADDR) {
    difftest_skip_ref();
    if(bool_time == 0) bool_time = cur_us;
    uint64_t up_time = cur_us - bool_time;
    return (uint32_t)(up_time & 0xFFFFFFFF);
  }
  else if(addr == RTC_ADDR + 4) {
    difftest_skip_ref();
    uint64_t up_time = cur_us - bool_time;
    return (uint32_t)(up_time >> 32);
  }
  return paddr_read(addr, 4);
}