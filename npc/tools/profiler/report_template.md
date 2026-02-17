# NPC Profiling Report

- Generated at: `{{GENERATED_AT}}`
- Profile directory: `{{PROFILE_DIR}}`

## Benchmark Summary

{{BENCHMARK_SECTIONS}}

## Notes

- `mispredict_flush_count` 和 `branch_penalty_cycles` 来自运行时 `flush/flushp` 事件日志。
- `flush_reason_histogram` 与 `flush_source_histogram` 用于区分 flush 根因及来源（ROB/外部）。
- `predict` 统计来自运行时 `[pred]` 汇总日志，按 `cond_branch/jump/return` 给出 hit/miss，并提供 `call_total`。
- `wrong_path_kill_uops` 与 `redirect_distance_*` 来自 flush 事件字段，用于估计错误路径清除开销。
