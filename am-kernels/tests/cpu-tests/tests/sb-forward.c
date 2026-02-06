#include "trap.h"

volatile signed char c;
volatile int x;

int main() {
  c = (signed char)0x80;
  x = (int)c;
  check(x == 0xffffff80);
  return 0;
}
