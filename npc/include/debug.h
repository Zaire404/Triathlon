#ifndef __DEBUG_H__
#define __DEBUG_H__

#include <common.h>
#include <utils.h>

#define Log(format, ...)                                                      \
  _Log(ANSI_FMT("[%s:%d %s] " format, ANSI_FG_BLUE) "\n", __FILE__, __LINE__, \
       __func__, ##__VA_ARGS__)

#endif