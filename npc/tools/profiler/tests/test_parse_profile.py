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


if __name__ == "__main__":
    unittest.main()
