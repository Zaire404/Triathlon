#ifndef __ISA_H__
#define __ISA_H__
#include <isa/isa-def.h>

//cpu
extern cpu_state CPU;
//reg
void isa_reg_display(cpu_state *cpu);
word_t isa_reg_str2val(const char *s, bool *success);

#endif