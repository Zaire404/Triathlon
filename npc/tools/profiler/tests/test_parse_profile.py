#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_parser_module():
    parser_path = Path(__file__).resolve().parents[1] / "parse_profile.py"
    spec = importlib.util.spec_from_file_location("parse_profile", parser_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load parser module from {parser_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ParseProfileTest(unittest.TestCase):
    def test_parse_single_log_basic_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "dhrystone.log"
            log.write_text(
                "\n".join(
                    [
                        "[flush ] cycle=10 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000000 redirect_pc=0x80000010 miss_type=cond_branch redirect_distance=16 killed_uops=5",
                        "[bru   ] cycle=10 valid=1 pc=0x80000000",
                        "[flushp] cycle=13 reason=branch_mispredict penalty=3",
                        "[flush ] cycle=30 reason=exception source=rob cause=0x2 src_pc=0x80000030 redirect_pc=0x80000100 miss_type=none redirect_distance=208 killed_uops=0",
                        "[flushp] cycle=36 reason=exception penalty=6",
                        "[pred  ] cond_total=5 cond_miss=1 cond_hit=4 jump_total=2 jump_miss=0 jump_hit=2",
                        "[commit] cycle=11 slot=0 pc=0x80000000 inst=0xfe0716e3 we=0 rd=x0 data=0x0 a0=0x0",
                        "[commit] cycle=11 slot=1 pc=0x80000004 inst=0x00100073 we=0 rd=x0 data=0x0 a0=0x0",
                        "[stall ] cycle=25 no_commit=20 fe(v/r/pc)=0/1/0x80000020 dec(v/r)=0/1 rob_ready=1 lsu_ld(v/r/addr)=0/1/0x0 lsu_rsp(v/r)=0/0 lsu_rs(b/r)=0x0/0x0 lsu_rs_head(v/idx/dst)=0/0x0/0x0 lsu_rs_head(rs1r/rs2r/has1/has2)=0/0/0/0 lsu_rs_head(q1/q2/sb)=0x0/0x0/0x0 lsu_rs_head(ld/st)=0/0 sb_alloc(req/ready/fire)=0x0/1/0 sb_dcache(v/r/addr)=0/1/0x0 ic_miss(v/r)=0/1 dc_miss(v/r)=0/1 flush=0 rdir=0x0 rob_head(fu/comp/is_store/pc)=0x1/1/0/0x80000000 rob_cnt=0 rob_ptr(h/t)=0x0/0x0 rob_q2(v/idx/fu/comp/st/pc)=0/0x0/0x0/0/0/0x0 sb(cnt/h/t)=0x0/0x0/0x0 sb_head(v/c/a/d/addr)=0/0/0/0/0x0",
                        "IPC=0.500000 CPI=2.000000 cycles=20 commits=10",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["cycles"], 20)
        self.assertEqual(result["commits"], 10)
        self.assertEqual(result["flush_count"], 2)
        self.assertEqual(result["bru_count"], 1)
        self.assertEqual(result["commit_width_hist"][2], 1)
        self.assertEqual(result["commit_width_hist"][0], 19)
        self.assertEqual(result["stall_category"]["frontend_empty"], 1)
        self.assertEqual(result["mispredict_flush_count"], 1)
        self.assertEqual(result["branch_penalty_cycles"], 3)
        self.assertEqual(result["flush_reason_histogram"]["branch_mispredict"], 1)
        self.assertEqual(result["flush_reason_histogram"]["exception"], 1)
        self.assertEqual(result["flush_source_histogram"]["rob"], 2)
        self.assertEqual(result["wrong_path_kill_uops"], 5)
        self.assertEqual(result["redirect_distance_samples"], 2)
        self.assertEqual(result["redirect_distance_max"], 208)
        self.assertEqual(result["predict"]["cond_total"], 5)
        self.assertEqual(result["predict"]["cond_miss"], 1)
        self.assertEqual(result["predict"]["jump_total"], 2)
        self.assertEqual(result["predict"]["jump_miss"], 0)

    def test_parse_log_directory_summary(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            (out / "dhrystone.log").write_text(
                "IPC=0.400000 CPI=2.500000 cycles=100 commits=40\n",
                encoding="utf-8",
            )
            (out / "coremark.log").write_text(
                "[flush ] cycle=30 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000020 redirect_pc=0x80000030 miss_type=jump redirect_distance=16 killed_uops=4\n"
                "[flushp] cycle=36 reason=branch_mispredict penalty=6\n"
                "[bru   ] cycle=30 valid=1 pc=0x80000020\n"
                "[pred  ] cond_total=7 cond_miss=0 cond_hit=7 jump_total=3 jump_miss=1 jump_hit=2\n"
                "IPC=0.500000 CPI=2.000000 cycles=200 commits=100\n",
                encoding="utf-8",
            )

            summary = mod.parse_log_directory(out)

        self.assertIn("dhrystone", summary)
        self.assertIn("coremark", summary)
        self.assertAlmostEqual(summary["coremark"]["flush_per_kinst"], 10.0)
        self.assertAlmostEqual(summary["coremark"]["bru_per_kinst"], 10.0)
        self.assertEqual(summary["coremark"]["mispredict_flush_count"], 1)
        self.assertEqual(summary["coremark"]["branch_penalty_cycles"], 6)
        self.assertEqual(summary["coremark"]["wrong_path_kill_uops"], 4)
        self.assertEqual(summary["coremark"]["predict"]["jump_miss"], 1)

    def test_parse_flush_noise_lines_are_normalized(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "garbage-prefix [flush ] cycle=11 reason=bra===nch_mispredict source=ros) cause=0x0 src_pc=0x80000000 redirect_pc=0x80000010 miss_type=cond_branch redirect_distance=16 killed_uops=5",
                        "[flush ] cycle=20 reason=bs       ranch_mispredict source=rob cause=0x0 src_pc=0x80000010 redirect_pc=0x80000020 miss_type=jump redirect_distance=16 killed_uops=3",
                        "[flush ] cycle=30 reason=exception source=rob cause=0x2 src_pc=0x80000020 redirect_pc=0x80000100 miss_type=none redirect_distance=224 killed_uops=0",
                        "[flushp] cycle=25 reason=branch_mis penalty=5",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        allowed_reason = {"branch_mispredict", "exception", "rob_other", "external", "unknown"}
        allowed_source = {"rob", "external", "unknown"}
        self.assertTrue(set(result["flush_reason_histogram"].keys()).issubset(allowed_reason))
        self.assertTrue(set(result["flush_source_histogram"].keys()).issubset(allowed_source))
        self.assertEqual(result["mispredict_flush_count"], 2)
        self.assertEqual(result["wrong_path_kill_uops"], 8)
        self.assertEqual(result["branch_penalty_cycles"], 5)

    def test_timeout_log_uses_commit_lines_and_timeout_cycles(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark_commit_sample.log"
            log.write_text(
                "\n".join(
                    [
                        "[commit] cycle=98 slot=0 pc=0x80000000 inst=0x00000013 we=1 rd=x1 data=0x1 a0=0x0",
                        "[commit] cycle=99 slot=0 pc=0x80000004 inst=0x00000013 we=1 rd=x2 data=0x2 a0=0x0",
                        "TIMEOUT after 100 cycles",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["cycles"], 100)
        self.assertEqual(result["commits"], 2)
        self.assertAlmostEqual(result["ipc"], 0.02)
        self.assertAlmostEqual(result["cpi"], 50.0)

    def test_report_has_no_recommendations_section(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            template = Path(__file__).resolve().parents[1] / "report_template.md"
            summary = {
                "dhrystone": {
                    "log_path": str(tdir / "dhrystone.log"),
                    "ipc": 0.4,
                    "cpi": 2.5,
                    "cycles": 100,
                    "commits": 40,
                    "flush_per_kinst": 10.0,
                    "bru_per_kinst": 8.0,
                    "commit_width_hist": {0: 60, 1: 20, 2: 10, 3: 5, 4: 5},
                    "stall_category": {},
                    "stall_total": 0,
                    "control": {"control_ratio": 0.2, "est_misp_per_kinst": 15.0},
                    "top_pc": [],
                }
            }
            report = mod.build_markdown_report(summary, template)

        self.assertNotIn("Suggested Next Steps", report)

    def test_parse_predict_breakdown_includes_return_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[pred  ] cond_total=10 cond_miss=4 cond_hit=6 jump_total=6 jump_miss=3 jump_hit=3 ret_total=3 ret_miss=2 ret_hit=1 call_total=5",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["predict"]["ret_total"], 3)
        self.assertEqual(result["predict"]["ret_miss"], 2)
        self.assertEqual(result["predict"]["ret_hit"], 1)
        self.assertAlmostEqual(result["predict"]["ret_miss_rate"], 2 / 3)
        self.assertEqual(result["predict"]["call_total"], 5)

    def test_parse_flush_subtype_return_count(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[flush ] cycle=40 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000100 redirect_pc=0x80000200 miss_type=return miss_subtype=return redirect_distance=256 killed_uops=6",
                        "[flushp] cycle=44 reason=branch_mispredict penalty=4",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["mispredict_flush_count"], 1)
        self.assertEqual(result["mispredict_ret_count"], 1)
        self.assertEqual(result["mispredict_cond_count"], 0)
        self.assertEqual(result["mispredict_jump_count"], 0)

    def test_decode_blocked_post_flush_window_metrics(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[flush ] cycle=10 reason=branch_mispredict source=rob cause=0x0 src_pc=0x80000000 redirect_pc=0x80000010 miss_type=cond_branch redirect_distance=16 killed_uops=4",
                        "[stall ] cycle=12 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_decode_blocked_total"], 2)
        self.assertEqual(result["stall_decode_blocked_post_flush"], 1)
        self.assertAlmostEqual(result["stall_decode_blocked_post_flush_ratio"], 0.5)
        self.assertEqual(result["stall_decode_blocked_post_branch_flush"], 1)
        self.assertAlmostEqual(result["stall_decode_blocked_post_branch_flush_ratio"], 0.5)
        self.assertEqual(result["stall_post_flush_window_cycles"], 16)

    def test_decode_blocked_detail_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 sb_alloc(req/ready/fire)=0x1/0/0",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs_head(v/idx/dst)=1/0x2/0x3 lsu_rs_head(rs1r/rs2r/has1/has2)=0/1/1/0",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs(b/r)=0xff/0x0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs_head(rs1r/rs2r/has1/has2)=1/0/1/1 rob_q2(v/idx/fu/comp/st/pc)=1/0x1/0x2/0/0/0x80000010",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/0 rob_ready=1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_decode_blocked_total"], 5)
        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["sb_alloc_blocked"], 1)
        self.assertEqual(detail["lsu_operand_wait"], 1)
        self.assertEqual(detail["lsu_rs_pressure"], 1)
        self.assertEqual(detail["rob_q2_wait"], 1)
        self.assertEqual(detail["other"], 1)

    def test_decode_blocked_detail_rob_q2_without_rs2_dependency(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_rs_head(rs1r/rs2r/has1/has2)=1/1/1/0 rob_q2(v/idx/fu/comp/st/pc)=1/0x1/0x2/0/0/0x80000010",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["other"], 1)
        self.assertEqual(detail.get("rob_q2_wait", 0), 0)

    def test_decode_blocked_detail_secondary_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 gate(alu/bru/lsu/mdu/csr)=1/1/0/1/1 need(alu/bru/lsu/mdu/csr)=0/0/1/0/0 free(alu/bru/lsu/csr)=8/8/0/8",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 gate(alu/bru/lsu/mdu/csr)=0/1/1/1/1 need(alu/bru/lsu/mdu/csr)=1/0/0/0/0 free(alu/bru/lsu/csr)=0/8/8/8",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_sm=1 lsu_ld_fire=0 lsu_rsp_fire=0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsu_sm=2 lsu_ld_fire=0 lsu_rsp_fire=0",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/0 rob_ready=1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["dispatch_gate_lsu"], 1)
        self.assertEqual(detail["dispatch_gate_alu"], 1)
        self.assertEqual(detail["lsu_wait_ld_req"], 1)
        self.assertEqual(detail["lsu_wait_ld_rsp"], 1)
        self.assertEqual(detail["other"], 1)

    def test_decode_blocked_detail_pending_replay_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/4/1/1/1",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/2/1/1/1",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/4/0/0/0",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 ren(pend/src/sel/fire/rdy)=1/1/0/0/0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["pending_replay_progress_full"], 1)
        self.assertEqual(detail["pending_replay_progress_has_room"], 1)
        self.assertEqual(detail["pending_replay_wait_full"], 1)
        self.assertEqual(detail["pending_replay_wait_has_room"], 1)

    def test_decode_blocked_detail_lsu_group_wait_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["lsug_no_free_lane"], 1)
        self.assertEqual(detail["lsug_wait_dcache_owner"], 1)

    def test_decode_blocked_detail_dcache_store_wait_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/0 rob_ready=1 dc_store_wait(same/full)=1/0",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/0 rob_ready=1 dc_store_wait(same/full)=0/1",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_decode_blocked_detail"]
        self.assertEqual(detail["dc_store_wait_same_line"], 1)
        self.assertEqual(detail["dc_store_wait_mshr_full"], 1)

    def test_rob_backpressure_detail_breakdown(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x1/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x2/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x6/0/0/0x8000001c",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x4/0/0/0x80000020",
                        "[stall ] cycle=60 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x5/0/0/0x80000024",
                        "[stall ] cycle=70 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x80000028 sb_head(v/c/a/d/addr)=1/0/1/1/0x00000100",
                        "[stall ] cycle=80 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x8000002c sb_head(v/c/a/d/addr)=1/1/0/1/0x00000100",
                        "[stall ] cycle=90 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x80000030 sb_head(v/c/a/d/addr)=1/1/1/0/0x00000100",
                        "[stall ] cycle=100 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/1/0x80000034 sb_head(v/c/a/d/addr)=1/1/1/1/0x00000100 sb_dcache(v/r/addr)=1/0/0x00000100",
                        "[stall ] cycle=110 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/1/0/0x80000038",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_category"]["rob_backpressure"], 11)
        self.assertEqual(result["stall_rob_backpressure_total"], 11)
        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_incomplete_no_sm"], 1)
        self.assertEqual(detail["rob_head_fu_alu_incomplete"], 1)
        self.assertEqual(detail["rob_head_fu_branch_incomplete"], 1)
        self.assertEqual(detail["rob_head_fu_csr_incomplete"], 1)
        self.assertEqual(detail["rob_head_fu_mdu_incomplete"], 2)
        self.assertEqual(detail["rob_store_wait_commit"], 1)
        self.assertEqual(detail["rob_store_wait_addr"], 1)
        self.assertEqual(detail["rob_store_wait_data"], 1)
        self.assertEqual(detail["rob_store_wait_dcache"], 1)
        self.assertEqual(detail["rob_head_complete_but_not_ready"], 1)

    def test_rob_backpressure_lsu_incomplete_secondary_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001000 lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=2 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=0/1 lsu_rsp_fire=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=2 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=3 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_rob_backpressure_total"], 4)
        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_rsp_valid"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_rsp_fire"], 1)
        self.assertEqual(detail["rob_lsu_wait_wb"], 1)

    def test_rob_backpressure_lsu_req_fire_detail_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x3/0/0x0/0x2 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=0/1 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=1/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=0/0/0x0 lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_wait_ld_owner_rsp_fire"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_owner_rsp_valid"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_owner_rsp_ready"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_arb_no_grant"], 1)

    def test_rob_backpressure_lsu_req_ready_detail_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001000 lsu_ld_fire=0 lsu_rsp(v/r)=1/1 lsu_rsp_fire=1 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x3/0/0x0/0x2 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001004 lsu_ld_fire=0 lsu_rsp(v/r)=0/1 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001008 lsu_ld_fire=0 lsu_rsp(v/r)=1/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x1/0/0x0/0x1 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x8000100c lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x0/0/0x0/0x0 dc_mshr(cnt/full/empty)=0/1/0 dc_mshr(alloc_rdy/line_hit)=0/0 sb_dcache(v/r/addr)=0/0/0x0 dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_ld(v/r/addr)=1/0/0x80001010 lsu_ld_fire=0 lsu_rsp(v/r)=0/0 lsu_rsp_fire=0 lsug(busy/alloc_fire/alloc_lane/ld_owner)=0x0/0/0x0/0x0 dc_mshr(cnt/full/empty)=0/0/1 dc_mshr(alloc_rdy/line_hit)=1/0 sb_dcache(v/r/addr)=1/0/0x80003e9c dc_miss(v/r)=0/1 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000020",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_owner_rsp_fire"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_owner_rsp_valid"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_owner_rsp_ready"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_mshr_blocked"], 1)
        self.assertEqual(detail["rob_lsu_wait_ld_req_ready_sb_conflict"], 1)

    def test_rob_backpressure_lsu_incomplete_fallback_split(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=10 no_commit=20 dec(v/r)=1/1 rob_ready=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000010",
                        "[stall ] cycle=20 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000014",
                        "[stall ] cycle=30 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=1 lsu_rsp(v/r)=0/0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000018",
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=2 lsu_ld(v/r/addr)=0/0/0x0 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x8000001c",
                        "[stall ] cycle=50 no_commit=20 dec(v/r)=1/1 rob_ready=0 lsu_sm=9 rob_head(fu/comp/is_store/pc)=0x3/0/0/0x80000020",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        detail = result["stall_rob_backpressure_detail"]
        self.assertEqual(detail["rob_lsu_incomplete_no_sm"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_idle"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_req_unknown"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_rsp_unknown"], 1)
        self.assertEqual(detail["rob_lsu_incomplete_sm_illegal"], 1)

    def test_cycle_stall_summary_takes_priority(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=40 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "[stallm] mode=cycle stall_total_cycles=60 flush_recovery=5 icache_miss_wait=7 dcache_miss_wait=3 rob_backpressure=20 frontend_empty=11 decode_blocked=9 lsu_req_blocked=1 other=4",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertEqual(result["stall_mode"], "cycle")
        self.assertEqual(result["stall_total"], 60)
        self.assertEqual(result["stall_category"]["rob_backpressure"], 20)
        self.assertEqual(result["stall_category"]["decode_blocked"], 9)
        self.assertEqual(result["stall_category"]["frontend_empty"], 11)

    def test_commit_summary_without_commit_detail(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[commitm] cycles=100 commits=50 width0=60 width1=20 width2=10 width3=5 width4=5",
                        "[controlm] branch_count=30 jal_count=10 jalr_count=5 branch_taken_count=18 call_count=7 ret_count=6",
                        "[hotpcm] rank0_pc=0x80000010 rank0_count=123 rank1_pc=0x80000020 rank1_count=77",
                        "[hotinstm] rank0_inst=0x00100073 rank0_count=40 rank1_inst=0x00000013 rank1_count=30",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertFalse(result["has_commit_detail"])
        self.assertTrue(result["has_commit_summary"])
        self.assertEqual(result["commit_width_hist"][0], 60)
        self.assertEqual(result["commit_width_hist"][4], 5)
        self.assertEqual(result["control"]["branch_count"], 30)
        self.assertEqual(result["control"]["jal_count"], 10)
        self.assertEqual(result["control"]["jalr_count"], 5)
        self.assertEqual(result["top_pc"][0]["pc"], "0x80000010")
        self.assertEqual(result["top_pc"][0]["count"], 123)
        self.assertEqual(result["top_inst"][0]["inst"], "0x00100073")
        self.assertEqual(result["top_inst"][0]["count"], 40)

    def test_quality_warning_for_sampled_stall_and_missing_commit(self):
        mod = load_parser_module()
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "coremark.log"
            log.write_text(
                "\n".join(
                    [
                        "[stall ] cycle=25 no_commit=20 dec(v/r)=1/0 rob_ready=1 flush=0",
                        "IPC=0.500000 CPI=2.000000 cycles=100 commits=50",
                    ]
                ),
                encoding="utf-8",
            )

            result = mod.parse_single_log(log)

        self.assertFalse(result["has_commit_detail"])
        self.assertFalse(result["has_commit_summary"])
        self.assertEqual(result["stall_mode"], "sampled")
        warnings = result["quality_warnings"]
        self.assertTrue(any("commit" in msg for msg in warnings))
        self.assertTrue(any("sampled" in msg for msg in warnings))


if __name__ == "__main__":
    unittest.main()
