#ifndef __COMMON_H__
#define __COMMON_H__

#define MBASE 0x80000000
#define MSIZE 0x8000000
#define CONFIG_FST_WAVE_TRACE 0 //生成波形
#define word_t uint32_t
#define paddr_t uint32_t
#define vaddr_t uint32_t
#define ARRLEN(arr) (sizeof(arr) / sizeof((arr)[0]))
#define FMT_WORD "0x%08" PRIx32
#define GPU_NUMBER 32
#define DIFFTEST_TO_REF 1
#define DIFFTEST_TO_DUT 0
#define RESET_NUMBER 10
#define Mtrace 0 //mtrace
#define Itrace 0 //itrace
#define SERIAL_MMIO 0xa00003f8 //串口地址
#define RTC_ADDR 0xa0000048 //时钟地址


#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <debug.h>
#include <string.h>
#include "verilated.h"
#include <Vcpu.h>
#endif
