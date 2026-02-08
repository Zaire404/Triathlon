#include "trap.h"

volatile unsigned int x;

int main() {
  for (int i = 0; i < 1000; i++) {
    x = 0x11223344u;
    asm volatile("" ::: "memory");
    unsigned char b = *(((volatile unsigned char *)&x) + 1);
    if (b != 0x33) {
      halt(11);
    }

    x = 0;
    asm volatile("" ::: "memory");
    *(((volatile unsigned char *)&x) + 1) = 0x55;
    asm volatile("" ::: "memory");
    unsigned int w = x;
    if (w != 0x00005500u) {
      halt(22);
    }
  }
  return 0;
}
