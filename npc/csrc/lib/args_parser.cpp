#include "args_parser.h"

namespace npc {

namespace {

bool parse_u64(const std::string &s, uint64_t &out) {
  try {
    size_t idx = 0;
    out = std::stoull(s, &idx, 0);
    return idx == s.size();
  } catch (...) {
    return false;
  }
}

}  // namespace

SimArgs parse_args(int argc, char **argv) {
  SimArgs args;
  for (int i = 1; i < argc; i++) {
    std::string arg = argv[i];

    if (arg == "-d") {
      if (i + 1 < argc) {
        args.difftest_so = argv[i + 1];
        i++;
      }
      continue;
    }
    if (arg.rfind("--difftest=", 0) == 0) {
      args.difftest_so = arg.substr(std::string("--difftest=").size());
      continue;
    }
    if (arg == "--max-cycles" && i + 1 < argc) {
      uint64_t v = 0;
      if (parse_u64(argv[i + 1], v)) {
        args.max_cycles = v;
        i++;
        continue;
      }
    }
    if (arg.rfind("--max-cycles=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--max-cycles=").size()), v)) {
        args.max_cycles = v;
      }
      continue;
    }
    if (arg == "--trace") {
      args.trace = true;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        args.trace_path = argv[i + 1];
        i++;
      }
      continue;
    }
    if (arg.rfind("--trace=", 0) == 0) {
      args.trace = true;
      args.trace_path = arg.substr(std::string("--trace=").size());
      continue;
    }
    if (arg == "--commit-trace") {
      args.commit_trace = true;
      continue;
    }
    if (arg == "--fe-trace") {
      args.fe_trace = true;
      continue;
    }
    if (arg == "--bru-trace") {
      args.bru_trace = true;
      continue;
    }
    if (arg == "--stall-trace") {
      args.stall_trace = true;
      if (i + 1 < argc) {
        uint64_t v = 0;
        if (parse_u64(argv[i + 1], v)) {
          args.stall_threshold = v;
          i++;
        }
      }
      continue;
    }
    if (arg.rfind("--stall-trace=", 0) == 0) {
      args.stall_trace = true;
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--stall-trace=").size()), v)) {
        args.stall_threshold = v;
      }
      continue;
    }
    if (arg == "--progress") {
      args.progress_interval = 1000000;
      if (i + 1 < argc && argv[i + 1][0] != '-') {
        uint64_t v = 0;
        if (parse_u64(argv[i + 1], v)) {
          args.progress_interval = v;
          i++;
        }
      }
      continue;
    }
    if (arg.rfind("--progress=", 0) == 0) {
      uint64_t v = 0;
      if (parse_u64(arg.substr(std::string("--progress=").size()), v)) {
        args.progress_interval = v;
      }
      continue;
    }
    if (!arg.empty() && arg[0] == '-') {
      continue;
    }
    args.img_path = arg;
  }
  return args;
}

}  // namespace npc
