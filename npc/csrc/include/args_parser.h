#pragma once

#include <cstdint>
#include <string>

namespace npc {

struct SimArgs {
  std::string img_path;
  uint64_t max_cycles = 600000000;
  std::string difftest_so;
  bool trace = false;
  std::string trace_path = "npc.vcd";
  bool commit_trace = false;
  bool fe_trace = false;
  bool bru_trace = false;
  bool stall_trace = false;
  uint64_t stall_threshold = 200;
  uint64_t progress_interval = 0;
};

SimArgs parse_args(int argc, char **argv);

}  // namespace npc
