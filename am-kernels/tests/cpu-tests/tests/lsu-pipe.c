#include "trap.h"

volatile int mem_area[4] __attribute__((aligned(64)));

int main() {
  mem_area[0] = 0x11;
  mem_area[1] = 0x22;
  mem_area[2] = 0x33;
  mem_area[3] = 0x44;

  int a = mem_area[0];        // cold load -> miss
  mem_area[1] = 0x12345678;   // independent store
  int b = mem_area[1];        // should forward from SB
  int c = mem_area[2];

  check(a == 0x11);
  check(b == 0x12345678);
  check(c == 0x33);
  return 0;
}
