#pragma once

#include <cstdint>
#include <string>

#include "logger/snapshot.h"

struct LogConfig {
  bool commit_trace = false;
  bool fe_trace = false;
  bool bru_trace = false;
  bool stall_trace = false;
  uint64_t stall_threshold = 0;
  uint64_t progress_interval = 0;
};

class Logger {
 public:
  static void init(const LogConfig &config);
  static void shutdown();

  static void log_commit(uint64_t cycle,
                         uint32_t slot,
                         uint32_t pc,
                         uint32_t inst,
                         bool we,
                         uint32_t rd,
                         uint32_t data,
                         uint32_t a0);
  static void log_stall(const Snapshot &snap);
  static void log_progress(const Snapshot &snap);
  static void log_perf(const Snapshot &snap, double ipc, double cpi);
  static void log_info(const std::string &msg);
  static void log_warn(const std::string &msg);

  static const LogConfig &config();

 private:
  static std::string format_stall(const Snapshot &snap);
  static std::string format_progress(const Snapshot &snap);
};
