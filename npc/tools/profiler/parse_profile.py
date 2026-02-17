#!/usr/bin/env python3
"""Parse NPC profiling logs and generate a fixed markdown report."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

IPC_RE = re.compile(r"IPC=([0-9]+(?:\.[0-9]+)?)\s+CPI=([0-9]+(?:\.[0-9]+)?)\s+cycles=(\d+)\s+commits=(\d+)")
TIMEOUT_RE = re.compile(r"TIMEOUT after (\d+) cycles")
FLUSH_RE = re.compile(r"^\[flush \]\s+cycle=(\d+)(?:\s+reason=([a-zA-Z0-9_]+))?")
FLUSHP_RE = re.compile(r"^\[flushp\]\s+cycle=(\d+)\s+reason=([a-zA-Z0-9_]+)\s+penalty=(\d+)")
BRU_RE = re.compile(r"^\[bru\s+\]\s+cycle=(\d+)")
COMMIT_RE = re.compile(r"^\[commit\]\s+cycle=(\d+)\s+slot=(\d+)\s+pc=0x([0-9a-fA-F]+)\s+inst=0x([0-9a-fA-F]+)")
STALL_RE = re.compile(r"^\[stall \]")
KV_RE = re.compile(r"([a-zA-Z_][a-zA-Z0-9_]*)=([^\s]+)")

FLUSH_REASON_ALLOWLIST = {"branch_mispredict", "exception", "rob_other", "external", "unknown"}
FLUSH_SOURCE_ALLOWLIST = {"rob", "external", "unknown"}
MISS_TYPE_ALLOWLIST = {"cond_branch", "jump", "return", "control_unknown", "none"}


def _safe_div(numer: float, denom: float) -> float:
    return 0.0 if denom == 0 else numer / denom


def _parse_kv_pairs(line: str) -> dict[str, str]:
    return {m.group(1): m.group(2) for m in KV_RE.finditer(line)}


def _parse_int(token: str | None, default: int = 0) -> int:
    if token is None:
        return default
    try:
        return int(token, 0)
    except ValueError:
        return default


def _compact_alpha(token: str) -> str:
    return re.sub(r"[^a-z]", "", token.lower())


def _normalize_flush_reason(token: str | None, line_ctx: str = "") -> str:
    raw = "" if token is None else token.strip().lower()
    if raw in FLUSH_REASON_ALLOWLIST:
        return raw

    compact = _compact_alpha(raw)
    ctx = _compact_alpha(line_ctx)

    if "except" in compact or "except" in ctx:
        return "exception"
    if "robother" in compact or "robother" in ctx:
        return "rob_other"
    if "extern" in compact or "extern" in ctx:
        return "external"
    if "unknown" in compact:
        return "unknown"
    if ("misp" in compact or "mispr" in compact or "misp" in ctx or "mispr" in ctx) and (
        "branch" in compact or "ranch" in compact or "branch" in ctx or "ranch" in ctx
    ):
        return "branch_mispredict"
    return "unknown"


def _normalize_flush_source(token: str | None) -> str:
    raw = "" if token is None else token.strip().lower()
    if raw in FLUSH_SOURCE_ALLOWLIST:
        return raw

    compact = _compact_alpha(raw)
    if "rob" in compact:
        return "rob"
    if "extern" in compact:
        return "external"
    if "unknown" in compact:
        return "unknown"
    return "unknown"


def _normalize_miss_type(token: str | None) -> str:
    raw = "" if token is None else token.strip().lower()
    if raw in MISS_TYPE_ALLOWLIST:
        return raw

    compact = _compact_alpha(raw)
    if compact.startswith("ret") or "return" in compact:
        return "return"
    if "jump" in compact or compact.startswith("jal"):
        return "jump"
    if "control" in compact:
        return "control_unknown"
    if "none" in compact:
        return "none"
    if "cond" in compact and "branch" in compact:
        return "cond_branch"
    return "none"


def _classify_stall(line: str) -> str:
    def pair(pattern: str) -> tuple[int, int] | None:
        m = re.search(pattern, line)
        if not m:
            return None
        return int(m.group(1)), int(m.group(2))

    def scalar(pattern: str, default: int = 0) -> int:
        m = re.search(pattern, line)
        return default if not m else int(m.group(1))

    flush = scalar(r"\sflush=(\d)")
    ic = pair(r"ic_miss\(v/r\)=(\d)/(\d)")
    dc = pair(r"dc_miss\(v/r\)=(\d)/(\d)")
    rob_ready = scalar(r"\srob_ready=(\d)", 1)
    dec = pair(r"dec\(v/r\)=(\d)/(\d)")
    lsu_issue = pair(r"lsu_issue\(v/r\)=(\d)/(\d)")

    if flush == 1:
        return "flush_recovery"
    if ic and ic[0] == 1:
        return "icache_miss_wait"
    if dc and dc[0] == 1:
        return "dcache_miss_wait"
    if rob_ready == 0:
        return "rob_backpressure"
    if dec and dec[0] == 0:
        return "frontend_empty"
    if dec and dec[0] == 1 and dec[1] == 0:
        return "decode_blocked"
    if lsu_issue and lsu_issue[0] == 1 and lsu_issue[1] == 0:
        return "lsu_req_blocked"
    return "other"


def _commit_histogram(cycles: int, commit_by_cycle: dict[int, int]) -> dict[int, int]:
    hist = Counter(commit_by_cycle.values())
    if cycles > 0:
        hist[0] = max(0, cycles - len(commit_by_cycle))
    for width in range(5):
        hist.setdefault(width, 0)
    return {k: hist[k] for k in sorted(hist)}


def _control_flow_metrics(commit_seq: list[tuple[int, int, int, int]]) -> dict[str, float | int]:
    def is_call(inst: int) -> bool:
        opcode = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        if opcode == 0x6F:  # JAL
            return rd in (1, 5)
        if opcode == 0x67:  # JALR
            return rd in (1, 5)
        return False

    def is_ret(inst: int) -> bool:
        opcode = inst & 0x7F
        if opcode != 0x67:  # JALR
            return False
        rd = (inst >> 7) & 0x1F
        rs1 = (inst >> 15) & 0x1F
        imm12 = (inst >> 20) & 0xFFF
        return rd == 0 and rs1 in (1, 5) and imm12 == 0

    commit_seq.sort()
    branch_count = 0
    jal_count = 0
    jalr_count = 0
    branch_taken = 0
    call_count = 0
    ret_count = 0

    for i in range(len(commit_seq) - 1):
        _, _, pc, inst = commit_seq[i]
        _, _, next_pc, _ = commit_seq[i + 1]
        opcode = inst & 0x7F
        if is_call(inst):
            call_count += 1
        if is_ret(inst):
            ret_count += 1
        if opcode == 0x63:
            branch_count += 1
            if next_pc != ((pc + 4) & 0xFFFFFFFF):
                branch_taken += 1
        elif opcode == 0x6F:
            jal_count += 1
        elif opcode == 0x67:
            jalr_count += 1

    commit_total = len(commit_seq)
    control_total = branch_count + jal_count + jalr_count
    est_misp = branch_taken + jal_count + jalr_count  # static not-taken proxy

    return {
        "branch_count": branch_count,
        "jal_count": jal_count,
        "jalr_count": jalr_count,
        "branch_taken_count": branch_taken,
        "call_count": call_count,
        "ret_count": ret_count,
        "control_count": control_total,
        "control_ratio": _safe_div(control_total, commit_total),
        "est_misp_count": est_misp,
        "est_misp_per_kinst": 1000.0 * _safe_div(est_misp, commit_total),
    }


def parse_single_log(path: str | Path) -> dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"log not found: {p}")

    ipc = 0.0
    cpi = 0.0
    cycles = 0
    commits = 0
    timeout_cycles = 0

    flush_count = 0
    bru_count = 0
    mispredict_flush_count = 0
    mispredict_cond_count = 0
    mispredict_jump_count = 0
    mispredict_ret_count = 0
    branch_penalty_cycles = 0
    wrong_path_kill_uops = 0
    redirect_distance_sum = 0
    redirect_distance_samples = 0
    redirect_distance_max = 0
    flush_reason_hist: Counter[str] = Counter()
    flush_source_hist: Counter[str] = Counter()

    pred_cond_total_line: int | None = None
    pred_cond_miss_line: int | None = None
    pred_jump_total_line: int | None = None
    pred_jump_miss_line: int | None = None
    pred_ret_total_line: int | None = None
    pred_ret_miss_line: int | None = None
    pred_call_total_line: int | None = None

    commit_by_cycle: dict[int, int] = defaultdict(int)
    commit_seq: list[tuple[int, int, int, int]] = []

    stall_counter: Counter[str] = Counter()
    hotspot_pc: Counter[int] = Counter()
    hotspot_inst: Counter[int] = Counter()

    for raw in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = IPC_RE.search(raw)
        if m:
            ipc = float(m.group(1))
            cpi = float(m.group(2))
            cycles = int(m.group(3))
            commits = int(m.group(4))
            continue

        m = TIMEOUT_RE.search(raw)
        if m:
            timeout_cycles = int(m.group(1))
            continue

        flush_pos = raw.find("[flush ]")
        if flush_pos >= 0:
            flush_line = raw[flush_pos:]
            flush_count += 1
            kv = _parse_kv_pairs(flush_line)
            reason_raw = kv.get("reason", "unknown")
            source_raw = kv.get("source", "unknown")
            miss_type_raw = kv.get("miss_subtype", kv.get("miss_type", "none"))
            redirect_distance = _parse_int(kv.get("redirect_distance"), 0)
            killed_uops = _parse_int(kv.get("killed_uops"), 0)

            # Backward compatibility for old log format: [flush ] cycle=... reason=...
            if reason_raw == "unknown":
                m = FLUSH_RE.match(flush_line)
                if m and m.group(2):
                    reason_raw = m.group(2)

            reason = _normalize_flush_reason(reason_raw, flush_line)
            source = _normalize_flush_source(source_raw)
            miss_type = _normalize_miss_type(miss_type_raw)

            flush_reason_hist[reason] += 1
            flush_source_hist[source] += 1
            redirect_distance_sum += redirect_distance
            redirect_distance_samples += 1
            redirect_distance_max = max(redirect_distance_max, redirect_distance)

            if reason == "branch_mispredict":
                mispredict_flush_count += 1
                wrong_path_kill_uops += killed_uops
                if miss_type == "cond_branch":
                    mispredict_cond_count += 1
                elif miss_type == "jump":
                    mispredict_jump_count += 1
                elif miss_type == "return":
                    mispredict_ret_count += 1
            continue

        flushp_pos = raw.find("[flushp]")
        if flushp_pos >= 0:
            m = FLUSHP_RE.match(raw[flushp_pos:])
            if not m:
                continue
            reason = _normalize_flush_reason(m.group(2), raw[flushp_pos:])
            penalty = int(m.group(3))
            if reason == "branch_mispredict":
                branch_penalty_cycles += penalty
            continue

        if BRU_RE.match(raw):
            bru_count += 1
            continue

        pred_pos = raw.find("[pred")
        if pred_pos >= 0:
            pred_kv = _parse_kv_pairs(raw[pred_pos:])
            if "cond_total" in pred_kv:
                pred_cond_total_line = _parse_int(pred_kv.get("cond_total"), 0)
            if "cond_miss" in pred_kv:
                pred_cond_miss_line = _parse_int(pred_kv.get("cond_miss"), 0)
            if "jump_total" in pred_kv:
                pred_jump_total_line = _parse_int(pred_kv.get("jump_total"), 0)
            if "jump_miss" in pred_kv:
                pred_jump_miss_line = _parse_int(pred_kv.get("jump_miss"), 0)
            if "ret_total" in pred_kv:
                pred_ret_total_line = _parse_int(pred_kv.get("ret_total"), 0)
            if "ret_miss" in pred_kv:
                pred_ret_miss_line = _parse_int(pred_kv.get("ret_miss"), 0)
            if "call_total" in pred_kv:
                pred_call_total_line = _parse_int(pred_kv.get("call_total"), 0)
            continue

        m = COMMIT_RE.match(raw)
        if m:
            cycle = int(m.group(1))
            slot = int(m.group(2))
            pc = int(m.group(3), 16)
            inst = int(m.group(4), 16)
            commit_by_cycle[cycle] += 1
            commit_seq.append((cycle, slot, pc, inst))
            hotspot_pc[pc] += 1
            hotspot_inst[inst] += 1
            continue

        if STALL_RE.match(raw):
            stall_counter[_classify_stall(raw)] += 1

    commit_width_hist = _commit_histogram(cycles, commit_by_cycle)
    control = _control_flow_metrics(commit_seq)

    cond_total = int(control.get("branch_count", 0))
    jump_total = int(control.get("jal_count", 0)) + int(control.get("jalr_count", 0))
    ret_total = int(control.get("ret_count", 0))
    call_total = int(control.get("call_count", 0))
    cond_miss = mispredict_cond_count
    jump_miss = mispredict_jump_count
    ret_miss = mispredict_ret_count
    if pred_cond_total_line is not None:
        cond_total = pred_cond_total_line
    if pred_cond_miss_line is not None:
        cond_miss = pred_cond_miss_line
    if pred_jump_total_line is not None:
        jump_total = pred_jump_total_line
    if pred_jump_miss_line is not None:
        jump_miss = pred_jump_miss_line
    if pred_ret_total_line is not None:
        ret_total = pred_ret_total_line
    if pred_ret_miss_line is not None:
        ret_miss = pred_ret_miss_line
    if pred_call_total_line is not None:
        call_total = pred_call_total_line
    cond_hit = max(0, cond_total - cond_miss)
    jump_hit = max(0, jump_total - jump_miss)
    ret_hit = max(0, ret_total - ret_miss)
    predict = {
        "cond_total": cond_total,
        "cond_miss": cond_miss,
        "cond_hit": cond_hit,
        "cond_miss_rate": _safe_div(cond_miss, cond_total),
        "jump_total": jump_total,
        "jump_miss": jump_miss,
        "jump_hit": jump_hit,
        "jump_miss_rate": _safe_div(jump_miss, jump_total),
        "ret_total": ret_total,
        "ret_miss": ret_miss,
        "ret_hit": ret_hit,
        "ret_miss_rate": _safe_div(ret_miss, ret_total),
        "call_total": call_total,
    }

    # Fallback path for timeout/sample logs without final IPC line.
    if cycles == 0 and timeout_cycles > 0:
        cycles = timeout_cycles
    if commits == 0 and commit_seq:
        commits = len(commit_seq)
    if ipc == 0.0 and cycles > 0 and commits > 0:
        ipc = commits / cycles
    if cpi == 0.0 and commits > 0 and cycles > 0:
        cpi = cycles / commits

    # Recompute width histogram when cycles were recovered from timeout line.
    commit_width_hist = _commit_histogram(cycles, commit_by_cycle)

    return {
        "log_path": str(p),
        "ipc": ipc,
        "cpi": cpi,
        "cycles": cycles,
        "commits": commits,
        "flush_count": flush_count,
        "bru_count": bru_count,
        "mispredict_flush_count": mispredict_flush_count,
        "mispredict_cond_count": mispredict_cond_count,
        "mispredict_jump_count": mispredict_jump_count,
        "mispredict_ret_count": mispredict_ret_count,
        "mispredict_breakdown": {
            "cond_branch": mispredict_cond_count,
            "jump": mispredict_jump_count,
            "return": mispredict_ret_count,
        },
        "branch_penalty_cycles": branch_penalty_cycles,
        "wrong_path_kill_uops": wrong_path_kill_uops,
        "redirect_distance_sum": redirect_distance_sum,
        "redirect_distance_samples": redirect_distance_samples,
        "redirect_distance_avg": _safe_div(redirect_distance_sum, redirect_distance_samples),
        "redirect_distance_max": redirect_distance_max,
        "flush_reason_histogram": dict(flush_reason_hist),
        "flush_source_histogram": dict(flush_source_hist),
        "flush_per_kinst": 1000.0 * _safe_div(flush_count, commits),
        "bru_per_kinst": 1000.0 * _safe_div(bru_count, commits),
        "commit_width_hist": commit_width_hist,
        "stall_category": dict(stall_counter),
        "stall_total": sum(stall_counter.values()),
        "top_pc": [{"pc": f"0x{pc:08x}", "count": cnt} for pc, cnt in hotspot_pc.most_common(10)],
        "top_inst": [{"inst": f"0x{inst:08x}", "count": cnt} for inst, cnt in hotspot_inst.most_common(10)],
        "control": control,
        "predict": predict,
    }


def parse_log_directory(log_dir: str | Path) -> dict[str, Any]:
    d = Path(log_dir)
    summary: dict[str, Any] = {}

    candidates = {
        "dhrystone": ["dhrystone.log", "dhrystone_full.log"],
        "coremark": ["coremark.log", "coremark_full.log"],
        "coremark_sample": ["coremark_commit_sample.log"],
    }

    for bench, names in candidates.items():
        chosen = None
        for name in names:
            fp = d / name
            if fp.exists():
                chosen = fp
                break
        if chosen is None:
            continue
        summary[bench] = parse_single_log(chosen)

    return summary


def _fmt_pct(part: int, total: int) -> str:
    return "0.00%" if total == 0 else f"{(part * 100.0 / total):.2f}%"


def _bench_markdown(name: str, data: dict[str, Any]) -> str:
    hist = data.get("commit_width_hist", {})
    stall = data.get("stall_category", {})
    stall_total = data.get("stall_total", 0)
    control = data.get("control", {})
    flush_hist = data.get("flush_reason_histogram", {})
    flush_src_hist = data.get("flush_source_histogram", {})
    predict = data.get("predict", {})

    lines = [
        f"### {name}",
        "",
        f"- IPC/CPI: `{data.get('ipc', 0):.6f}` / `{data.get('cpi', 0):.6f}`",
        f"- cycles/commits: `{data.get('cycles', 0)}` / `{data.get('commits', 0)}`",
        f"- flush_per_kinst: `{data.get('flush_per_kinst', 0):.3f}`",
        f"- bru_per_kinst: `{data.get('bru_per_kinst', 0):.3f}`",
        f"- mispredict_flush_count: `{data.get('mispredict_flush_count', 0)}`",
        f"- branch_penalty_cycles: `{data.get('branch_penalty_cycles', 0)}`",
        f"- wrong_path_kill_uops: `{data.get('wrong_path_kill_uops', 0)}`",
        f"- redirect_distance_avg/max: `{data.get('redirect_distance_avg', 0):.2f}` / `{data.get('redirect_distance_max', 0)}`",
        f"- control_ratio: `{control.get('control_ratio', 0) * 100.0:.2f}%`",
        f"- est_misp_per_kinst(static NT proxy): `{control.get('est_misp_per_kinst', 0):.3f}`",
        f"- predict(cond hit/miss): `{predict.get('cond_hit', 0)}` / `{predict.get('cond_miss', 0)}` (miss_rate `{predict.get('cond_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(jump hit/miss): `{predict.get('jump_hit', 0)}` / `{predict.get('jump_miss', 0)}` (miss_rate `{predict.get('jump_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(ret hit/miss): `{predict.get('ret_hit', 0)}` / `{predict.get('ret_miss', 0)}` (miss_rate `{predict.get('ret_miss_rate', 0) * 100.0:.2f}%`)",
        f"- predict(call total): `{predict.get('call_total', 0)}`",
        "",
        "Commit Width Histogram:",
        f"- width0: `{hist.get(0, 0)}`",
        f"- width1: `{hist.get(1, 0)}`",
        f"- width2: `{hist.get(2, 0)}`",
        f"- width3: `{hist.get(3, 0)}`",
        f"- width4: `{hist.get(4, 0)}`",
        "",
        "Stall Categories:",
    ]

    if stall_total == 0:
        lines.append("- (no stall samples)")
    else:
        for key, val in sorted(stall.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}` ({_fmt_pct(val, stall_total)})")

    lines.append("")
    lines.append("Flush Reasons:")
    if flush_hist:
        for key, val in sorted(flush_hist.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}`")
    else:
        lines.append("- (no flush samples)")

    lines.append("")
    lines.append("Flush Sources:")
    if flush_src_hist:
        for key, val in sorted(flush_src_hist.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"- {key}: `{val}`")
    else:
        lines.append("- (no flush samples)")

    if data.get("top_pc"):
        lines.extend(["", "Top PC Hotspots:"])
        for item in data["top_pc"][:5]:
            lines.append(f"- {item['pc']}: `{item['count']}`")

    return "\n".join(lines)


def build_markdown_report(summary: dict[str, Any], template_path: str | Path) -> str:
    t = Path(template_path).read_text(encoding="utf-8")
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    bench_order = ["dhrystone", "coremark", "coremark_sample"]
    sections = []
    for name in bench_order:
        if name in summary:
            sections.append(_bench_markdown(name, summary[name]))
    body = "\n\n".join(sections) if sections else "(No benchmark logs found)"

    rendered = t
    rendered = rendered.replace("{{GENERATED_AT}}", now)
    rendered = rendered.replace("{{PROFILE_DIR}}", str(Path(summary[next(iter(summary))]["log_path"]).parent) if summary else "N/A")
    rendered = rendered.replace("{{BENCHMARK_SECTIONS}}", body)
    return rendered


def main() -> int:
    ap = argparse.ArgumentParser(description="Parse NPC profiler logs and generate report")
    ap.add_argument("--log-dir", required=True, help="Directory containing benchmark logs")
    ap.add_argument("--template", default="report_template.md", help="Markdown template path")
    ap.add_argument("--out-json", default="summary.json", help="Output summary json path")
    ap.add_argument("--out-md", default="report.md", help="Output markdown report path")
    args = ap.parse_args()

    log_dir = Path(args.log_dir)
    summary = parse_log_directory(log_dir)

    out_json = Path(args.out_json)
    if not out_json.is_absolute():
        out_json = log_dir / out_json
    out_json.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    template = Path(args.template)
    if not template.is_absolute():
        template = Path(__file__).resolve().parent / template

    out_md = Path(args.out_md)
    if not out_md.is_absolute():
        out_md = log_dir / out_md
    out_md.write_text(build_markdown_report(summary, template), encoding="utf-8")

    print(f"[profiler] summary json: {out_json}")
    print(f"[profiler] report md: {out_md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
