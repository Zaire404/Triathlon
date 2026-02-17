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
FLUSH_RE = re.compile(r"^\[flush \]\s+cycle=(\d+)")
BRU_RE = re.compile(r"^\[bru\s+\]\s+cycle=(\d+)")
COMMIT_RE = re.compile(r"^\[commit\]\s+cycle=(\d+)\s+slot=(\d+)\s+pc=0x([0-9a-fA-F]+)\s+inst=0x([0-9a-fA-F]+)")
STALL_RE = re.compile(r"^\[stall \]")


def _safe_div(numer: float, denom: float) -> float:
    return 0.0 if denom == 0 else numer / denom


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
    commit_seq.sort()
    branch_count = 0
    jal_count = 0
    jalr_count = 0
    branch_taken = 0

    for i in range(len(commit_seq) - 1):
        _, _, pc, inst = commit_seq[i]
        _, _, next_pc, _ = commit_seq[i + 1]
        opcode = inst & 0x7F
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

        if FLUSH_RE.match(raw):
            flush_count += 1
            continue

        if BRU_RE.match(raw):
            bru_count += 1
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
        "flush_per_kinst": 1000.0 * _safe_div(flush_count, commits),
        "bru_per_kinst": 1000.0 * _safe_div(bru_count, commits),
        "commit_width_hist": commit_width_hist,
        "stall_category": dict(stall_counter),
        "stall_total": sum(stall_counter.values()),
        "top_pc": [{"pc": f"0x{pc:08x}", "count": cnt} for pc, cnt in hotspot_pc.most_common(10)],
        "top_inst": [{"inst": f"0x{inst:08x}", "count": cnt} for inst, cnt in hotspot_inst.most_common(10)],
        "control": control,
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

    lines = [
        f"### {name}",
        "",
        f"- IPC/CPI: `{data.get('ipc', 0):.6f}` / `{data.get('cpi', 0):.6f}`",
        f"- cycles/commits: `{data.get('cycles', 0)}` / `{data.get('commits', 0)}`",
        f"- flush_per_kinst: `{data.get('flush_per_kinst', 0):.3f}`",
        f"- bru_per_kinst: `{data.get('bru_per_kinst', 0):.3f}`",
        f"- control_ratio: `{control.get('control_ratio', 0) * 100.0:.2f}%`",
        f"- est_misp_per_kinst(static NT proxy): `{control.get('est_misp_per_kinst', 0):.3f}`",
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
