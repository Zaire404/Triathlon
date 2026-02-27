#include "Vtb_triathlon.h"
#include "args_parser.h"
#include "boot_loader.h"
#include "difftest_client.h"
#include "memory_models.h"
#include "profile_collector.h"
#include "trap_decode.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  npc::SimArgs args = npc::parse_args(argc, argv);

  if (args.img_path.empty()) {
    std::cerr << "Usage: " << argv[0]
              << " <IMG> [--max-cycles N] [-d REF_SO] [--trace [vcd]] [--commit-trace]"
              << " [--bru-trace] [--fe-trace] [--stall-trace [N]] [--boot-handoff]"
              << " [--dtb <path>] [--firmware-load-base <addr>]"
              << " [--virtio-blk-image <path>]"
              << " [--progress [N]]\n";
    return 1;
  }

  npc::MemSystem mem;
  uint32_t entry_pc = npc::kPmemBase;
  if (args.boot_handoff) {
    const uint32_t firmware_base = (args.firmware_load_base != 0)
                                       ? static_cast<uint32_t>(args.firmware_load_base)
                                       : npc::kOpenSbiLoadBase;
    if (firmware_base == entry_pc) {
      std::ios::fmtflags f(std::cerr.flags());
      std::cerr << "[boot] firmware-load-base 0x" << std::hex << firmware_base
                << " overlaps reset trampoline at 0x" << entry_pc
                << std::dec << "\n";
      std::cerr.flags(f);
      return 1;
    }
    if ((firmware_base & 0x003fffffu) != 0u) {
      std::ios::fmtflags f(std::cerr.flags());
      std::cerr << "[boot] firmware-load-base 0x" << std::hex << firmware_base
                << " is not 4MiB aligned; RV32 Linux setup_vm() will hit BUG_ON.\n"
                << "[boot] use 0x80400000 (recommended) or another 0x400000-aligned address."
                << std::dec << "\n";
      std::cerr.flags(f);
      return 1;
    }
    if (!mem.mem.load_binary(args.img_path, firmware_base)) return 1;

    npc::BootHandoff handoff = npc::make_default_boot_handoff();
    if (!args.dtb_path.empty()) {
      if (!mem.mem.load_binary(args.dtb_path, handoff.dtb_addr)) return 1;
    } else {
      npc::install_minimal_dtb(mem.mem, handoff.dtb_addr);
    }
    npc::install_boot_handoff_stub(mem.mem, firmware_base, handoff, npc::kBootRomBase);
    npc::install_jump_stub(mem.mem, npc::kBootRomBase, entry_pc);
  } else {
    if (!mem.mem.load_binary(args.img_path, npc::kPmemBase)) return 1;
  }
  if (!args.virtio_blk_image.empty()) {
    if (!mem.mem.load_virtio_blk_image(args.virtio_blk_image)) return 1;
  }
  mem.icache.mem = &mem.mem;
  mem.dcache.mem = &mem.mem;

  auto *top = new Vtb_triathlon;
  VerilatedVcdC *tfp = nullptr;
  vluint64_t sim_time = 0;

#if VM_TRACE
  if (args.trace) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open(args.trace_path.c_str());
  }
#else
  if (args.trace) {
    std::cerr << "[warn] this binary is built without --trace support, ignore --trace\n";
  }
#endif

  npc::Difftest difftest;
  if (!args.difftest_so.empty()) {
    if (!difftest.init(args.difftest_so, mem.mem.pmem_words, entry_pc)) {
      if (tfp) tfp->close();
      delete top;
      return 1;
    }
  }
  mem.mem.uart_stdout_enabled = !difftest.enabled();

  npc::reset(top, mem, tfp, sim_time);
  auto make_low_mask = [](uint32_t width) -> uint32_t {
    if (width == 0u) return 0u;
    if (width >= 32u) return 0xFFFFFFFFu;
    return (1u << width) - 1u;
  };
  uint32_t cfg_instr_per_fetch = static_cast<uint32_t>(top->dbg_cfg_instr_per_fetch_o);
  if (cfg_instr_per_fetch == 0u || cfg_instr_per_fetch > 32u) {
    cfg_instr_per_fetch = 4u;
  }
  uint32_t cfg_commit_width = static_cast<uint32_t>(top->dbg_cfg_nret_o);
  if (cfg_commit_width == 0u || cfg_commit_width > 32u) {
    cfg_commit_width = 4u;
  }
  const uint32_t cfg_instr_mask = make_low_mask(cfg_instr_per_fetch);

  std::array<uint32_t, 32> rf{};
  uint64_t no_commit_cycles = 0;
  npc::ProfileCollector profile(args, cfg_instr_per_fetch, cfg_commit_width);
  uint32_t last_linux_wait_pc = 0xffffffffu;
  uint64_t last_linux_wait_log_cycle = 0;

  for (uint64_t cycles = 0; cycles < args.max_cycles; cycles++) {
    mem.mem.set_time_us(cycles);
    npc::tick(top, mem, tfp, sim_time);
    profile.observe_cycle(top);

    if (top->dbg_sb_dcache_req_valid_o && top->dbg_sb_dcache_req_ready_o) {
      uint32_t addr = top->dbg_sb_dcache_req_addr_o;
      uint32_t data = top->dbg_sb_dcache_req_data_o;
      uint32_t op = top->dbg_sb_dcache_req_op_o;
      mem.mem.write_store(addr, data, op);
      if (args.commit_trace) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[stwb  ] cycle=" << cycles
                  << " addr=0x" << std::hex << addr
                  << " data=0x" << data
                  << std::dec
                  << " op=" << op
                  << ((addr == npc::kSeed4Addr) ? " <seed4>" : "")
                  << "\n";
        std::cout.flags(f);
      }
    }

    if (args.commit_trace && top->dbg_lsu_ld_fire_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[ldreq ] cycle=" << cycles
                << " addr=0x" << std::hex << top->dbg_lsu_ld_req_addr_o
                << " tag=0x" << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                << ((top->dbg_lsu_ld_req_addr_o == npc::kSeed4Addr) ? " <seed4>" : "")
                << std::dec << "\n";
      std::cout.flags(f);
    }

    if (args.commit_trace && top->dbg_lsu_rsp_fire_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[ldrsp ] cycle=" << cycles
                << " addr=0x" << std::hex << top->dbg_lsu_inflight_addr_o
                << " tag=0x" << static_cast<uint32_t>(top->dbg_lsu_inflight_tag_o)
                << " data=0x" << top->dbg_lsu_ld_rsp_data_o
                << std::dec
                << " err=" << static_cast<int>(top->dbg_lsu_ld_rsp_err_o)
                << ((top->dbg_lsu_inflight_addr_o == npc::kSeed4Addr) ? " <seed4>" : "")
                << "\n";
      std::cout.flags(f);
    }

    profile.record_flush(cycles, top, mem.mem);

    if (!args.boot_handoff && top->backend_flush_o && top->dbg_rob_flush_o &&
        top->dbg_rob_flush_is_exception_o) {
      uint32_t src_pc = top->dbg_rob_flush_src_pc_o;
      uint32_t src_inst = mem.mem.read_word(src_pc);
      if (npc::is_ebreak_insn_word(src_inst, src_pc)) {
        uint32_t code = rf[10];
        if (code == 0) {
          std::cout << "HIT GOOD TRAP\n";
          double ipc = cycles ? static_cast<double>(profile.total_commits()) / static_cast<double>(cycles) : 0.0;
          double cpi = profile.total_commits() ? static_cast<double>(cycles) / static_cast<double>(profile.total_commits()) : 0.0;
          std::cout << "IPC=" << ipc << " CPI=" << cpi
                    << " cycles=" << cycles
                    << " commits=" << profile.total_commits() << "\n";
          profile.emit_summary(cycles, top);
          if (tfp) tfp->close();
          delete top;
          return 0;
        }
        std::cout << "HIT BAD TRAP (code=" << code << ")\n";
        profile.emit_summary(cycles, top);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
    }

    if (args.bru_trace && top->dbg_bru_wb_valid_o) {
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[bruwb ] cycle=" << cycles
                << " pc=0x" << std::hex << top->dbg_bru_pc_o
                << " v1=0x" << top->dbg_bru_v1_o
                << " v2=0x" << top->dbg_bru_v2_o
                << " redirect=0x" << top->dbg_bru_redirect_pc_o
                << std::dec
                << " mispred=" << static_cast<int>(top->dbg_bru_mispred_o)
                << " is_jump=" << static_cast<int>(top->dbg_bru_is_jump_o)
                << " is_branch=" << static_cast<int>(top->dbg_bru_is_branch_o)
                << " op=" << static_cast<int>(top->dbg_bru_op_o)
                << "\n";
      std::cout.flags(f);
    }

    uint32_t commit_this_cycle = 0;
    for (uint32_t i = 0; i < cfg_commit_width; i++) {
      bool valid = (top->commit_valid_o >> i) & 0x1;
      if (!valid) continue;
      commit_this_cycle++;

      std::array<uint32_t, 32> rf_before = rf;

      bool we = (top->commit_we_o >> i) & 0x1;
      uint32_t rd = (top->commit_areg_o >> (i * 5)) & 0x1F;
      uint32_t data = top->commit_wdata_o[i];
      if (we && rd != 0) {
        rf[rd] = data;
      }

      uint32_t pc = top->commit_pc_o[i];
      uint32_t inst = mem.mem.read_word(pc);
      profile.record_commit(pc, inst);
      if (args.commit_trace) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[commit] cycle=" << cycles
                  << " slot=" << i
                  << " pc=0x" << std::hex << pc
                  << " inst=0x" << inst
                  << " we=" << std::dec << we
                  << " rd=x" << rd
                  << " data=0x" << std::hex << data
                  << " a0=0x" << rf[10]
                  << std::dec << "\n";
        std::cout.flags(f);
      }
      if (!difftest.step_and_check(cycles, pc, inst, rf_before, rf)) {
        std::cerr << "[difftest] stop on first mismatch\n";
        profile.emit_summary(cycles, top);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
      if (npc::is_ebreak_insn_word(inst, pc) && !args.boot_handoff) {
        uint32_t code = rf[10];
        if (code == 0) {
          std::cout << "HIT GOOD TRAP\n";
          double ipc = cycles ? static_cast<double>(profile.total_commits()) / static_cast<double>(cycles) : 0.0;
          double cpi = profile.total_commits() ? static_cast<double>(cycles) / static_cast<double>(profile.total_commits()) : 0.0;
          std::cout << "IPC=" << ipc << " CPI=" << cpi
                    << " cycles=" << cycles
                    << " commits=" << profile.total_commits() << "\n";
          profile.emit_summary(cycles, top);
          if (tfp) tfp->close();
          delete top;
          return 0;
        }
        std::cout << "HIT BAD TRAP (code=" << code << ")\n";
        profile.emit_summary(cycles, top);
        if (tfp) tfp->close();
        delete top;
        return 1;
      }
    }

    profile.record_commit_width(commit_this_cycle);

    if (commit_this_cycle != 0) {
      profile.on_commit_cycle(cycles);
      if (difftest.enabled()) {
        npc::DUTCSRState dut_csr = {};
        dut_csr.mtvec = top->dbg_csr_mtvec_o;
        dut_csr.mepc = top->dbg_csr_mepc_o;
        dut_csr.mstatus = top->dbg_csr_mstatus_o;
        dut_csr.mcause = top->dbg_csr_mcause_o;
        if (!difftest.check_arch_state(cycles, rf, dut_csr)) {
          std::cerr << "[difftest] stop on arch-state mismatch\n";
          profile.emit_summary(cycles, top);
          if (tfp) tfp->close();
          delete top;
          return 1;
        }
      }
      no_commit_cycles = 0;
    } else {
      no_commit_cycles++;
      profile.on_no_commit_cycle(cycles, no_commit_cycles, top);
    }

    if (args.progress_interval > 0 && cycles != 0 &&
        (cycles % args.progress_interval == 0)) {
      const uint32_t last_pc = profile.last_commit_pc();
      std::ios::fmtflags f(std::cout.flags());
      std::cout << "[progress] cycle=" << cycles
                << " commits=" << profile.total_commits()
                << " no_commit=" << no_commit_cycles
                << " last_pc=0x" << std::hex << last_pc
                << " last_inst=0x" << profile.last_commit_inst()
                << " a0=0x" << rf[10]
                << " rob_head(pc/comp/is_store/fu)=0x" << top->dbg_rob_head_pc_o
                << "/" << std::dec
                << static_cast<int>(top->dbg_rob_head_complete_o) << "/"
                << static_cast<int>(top->dbg_rob_head_is_store_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_rob_head_fu_o)
                << " rob_cnt=" << std::dec
                << static_cast<uint32_t>(top->dbg_rob_count_o)
                << " rob_ptr(h/t)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_rob_head_ptr_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_rob_tail_ptr_o)
                << std::dec
                << " rob_q2(v/idx/fu/comp/st/pc)=" << std::dec
                << static_cast<int>(top->dbg_rob_q2_valid_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_idx_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_rob_q2_fu_o)
                << std::dec << "/" << static_cast<int>(top->dbg_rob_q2_complete_o)
                << "/" << static_cast<int>(top->dbg_rob_q2_is_store_o)
                << "/0x" << std::hex << static_cast<uint32_t>(top->dbg_rob_q2_pc_o)
                << " sb(cnt/h/t)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_sb_count_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_sb_head_ptr_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_sb_tail_ptr_o)
                << " sb_head(v/c/a/d/addr)=" << std::dec
                << static_cast<int>(top->dbg_sb_head_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_head_committed_o) << "/"
                << static_cast<int>(top->dbg_sb_head_addr_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_head_data_valid_o) << "/0x"
                << std::hex << top->dbg_sb_head_addr_o
                << " sb_dcache(v/r/addr)= " << std::dec
                << static_cast<int>(top->dbg_sb_dcache_req_valid_o) << "/"
                << static_cast<int>(top->dbg_sb_dcache_req_ready_o) << "/0x"
                << std::hex << top->dbg_sb_dcache_req_addr_o
                << " dc_mshr(cnt/full/empty)=" << std::dec
                << static_cast<uint32_t>(top->dbg_dc_mshr_count_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_full_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_empty_o)
                << " dc_mshr(alloc_rdy/line_hit)="
                << static_cast<int>(top->dbg_dc_mshr_alloc_ready_o) << "/"
                << static_cast<int>(top->dbg_dc_mshr_req_line_hit_o)
                << " dc_store_wait(same/full)="
                << static_cast<int>(top->dbg_dc_store_wait_same_line_o) << "/"
                << static_cast<int>(top->dbg_dc_store_wait_mshr_full_o)
                << " lsu_issue(v/r)=" << std::dec
                << static_cast<int>(top->dbg_lsu_issue_valid_o) << "/"
                << static_cast<int>(top->dbg_lsu_req_ready_o)
                << " lsu_issue_ready=" << static_cast<int>(top->dbg_lsu_issue_ready_o)
                << " lsu_free=" << static_cast<uint32_t>(top->dbg_lsu_free_count_o)
                << " lsu_rs(b/r)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_lsu_rs_busy_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_ready_o)
                << " lsu_rs_head(v/idx/dst)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_valid_o) << "/0x"
                << std::hex << static_cast<uint32_t>(top->dbg_lsu_rs_head_idx_o)
                << "/0x" << static_cast<uint32_t>(top->dbg_lsu_rs_head_dst_o)
                << " lsu_rs_head(rs1r/rs2r/has1/has2)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_r1_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_r2_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_has_rs1_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_has_rs2_o)
                << " lsu_rs_head(q1/q2/sb)=0x" << std::hex
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_q1_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_q2_o) << "/0x"
                << static_cast<uint32_t>(top->dbg_lsu_rs_head_sb_id_o)
                << " lsu_rs_head(ld/st)=" << std::dec
                << static_cast<int>(top->dbg_lsu_rs_head_is_load_o) << "/"
                << static_cast<int>(top->dbg_lsu_rs_head_is_store_o)
                << " lsu_ld(v/r/rsp)="
                << static_cast<int>(top->dbg_lsu_ld_req_valid_o) << "/"
                << static_cast<int>(top->dbg_lsu_ld_req_ready_o) << "/"
                << static_cast<int>(top->dbg_lsu_ld_rsp_valid_o)
                << " flush=" << static_cast<int>(top->backend_flush_o)
                << " dc_miss(v/r)="
                << static_cast<int>(top->dcache_miss_req_valid_o) << "/"
                << static_cast<int>(top->dcache_miss_req_ready_i)
                << std::dec << "\n";
      if (last_pc >= 0x800408c0u && last_pc < 0x80040900u) {
        std::cout << "[progress][trap-debug] cycle=" << cycles
                  << " last_pc=0x" << std::hex << last_pc
                  << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                  << " mtvec=0x" << top->dbg_csr_mtvec_o
                  << " mepc=0x" << top->dbg_csr_mepc_o
                  << " mstatus=0x" << top->dbg_csr_mstatus_o
                  << " mcause=0x" << top->dbg_csr_mcause_o
                  << std::dec << "\n";
      }
      if (last_pc >= 0x804410c0u && last_pc < 0x80441140u) {
        const bool pc_changed = (last_pc != last_linux_wait_pc);
        const bool periodic_log = (cycles - last_linux_wait_log_cycle >= 1000000ull);
        if (pc_changed || periodic_log) {
          std::cout << "[progress][linux-wait-debug] cycle=" << cycles
                    << " last_pc=0x" << std::hex << last_pc
                    << " last_inst=0x" << profile.last_commit_inst()
                    << " priv=0x" << static_cast<uint32_t>(top->dbg_csr_priv_mode_o)
                    << " stvec=0x" << top->dbg_csr_stvec_o
                    << " sepc=0x" << top->dbg_csr_sepc_o
                    << " scause=0x" << top->dbg_csr_scause_o
                    << " stval=0x" << top->dbg_csr_stval_o
                    << " sstatus=0x" << top->dbg_csr_sstatus_o
                    << " satp=0x" << top->dbg_csr_satp_o
                    << " mtvec=0x" << top->dbg_csr_mtvec_o
                    << " mepc=0x" << top->dbg_csr_mepc_o
                    << " mstatus=0x" << top->dbg_csr_mstatus_o
                    << " mcause=0x" << top->dbg_csr_mcause_o
                    << std::dec << "\n";
          last_linux_wait_pc = last_pc;
          last_linux_wait_log_cycle = cycles;
        }
      }
      std::cout.flags(f);
    }

    if (args.fe_trace && top->dbg_fe_valid_o && top->dbg_fe_ready_o) {
      uint32_t base_pc = top->dbg_fe_pc_o;
      uint32_t mismatch_mask = 0;
      std::vector<uint32_t> fe_instrs(cfg_instr_per_fetch, 0);
      std::vector<uint32_t> mem_instrs(cfg_instr_per_fetch, 0);
      uint32_t slot_valid = static_cast<uint32_t>(top->dbg_fe_slot_valid_o) & cfg_instr_mask;
      for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
        fe_instrs[i] = top->dbg_fe_instrs_o[i];
        mem_instrs[i] = mem.mem.read_word(base_pc + static_cast<uint32_t>(i * 4));
        if (fe_instrs[i] != mem_instrs[i]) {
          mismatch_mask |= (1u << i);
        }
      }
      if (mismatch_mask != 0 || slot_valid != cfg_instr_mask) {
        std::ios::fmtflags f(std::cout.flags());
        std::cout << "[fe   ] cycle=" << cycles
                  << " pc=0x" << std::hex << base_pc
                  << " slot_valid=0x" << slot_valid
                  << " mismatch=0x" << mismatch_mask
                  << " pred={";
        for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << static_cast<uint32_t>(top->dbg_fe_pred_npc_o[i]);
        }
        std::cout << "}"
                  << " fe={";
        for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << fe_instrs[i];
        }
        std::cout << "} mem={";
        for (uint32_t i = 0; i < cfg_instr_per_fetch; i++) {
          if (i) std::cout << ",";
          std::cout << "0x" << mem_instrs[i];
        }
        std::cout << "}" << std::dec << "\n";
        std::cout.flags(f);
      }
    }
  }

  std::cerr << "TIMEOUT after " << args.max_cycles << " cycles\n";
  profile.emit_summary(args.max_cycles, top);
  if (tfp) tfp->close();
  delete top;
  return 1;
}
