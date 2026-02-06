#include <klib-macros.h>
#include "trap.h"

int main() {
  uint32_t x = 0;
  uint32_t cnt = 0;
  const uint32_t target = 16;
  const uint32_t max = 64;

  asm volatile(
      "1:\n"
      "  addi %[x], %[x], 1\n"
      "  addi %[cnt], %[cnt], 1\n"
      "  bne  %[x], %[target], 2f\n"
      "  j 3f\n"
      "2:\n"
      "  blt  %[cnt], %[max], 1b\n"
      "3:\n"
      : [x] "+r"(x), [cnt] "+r"(cnt)
      : [target] "r"(target), [max] "r"(max)
      : "memory");

  check(x == target);
  return 0;
}
