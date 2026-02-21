# A6 Phase 1 Backend/LSU Rewrite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove backend head-of-line completion stalls by rebuilding LSU into a high-concurrency subsystem and decoupling ROB head progress from LSU micro-state serialization.

**Architecture:** Keep frontend/BPU behavior stable in this phase, and focus on backend memory-execution path. Introduce explicit `LQ/SQ + mem-dep replay + completion event queue` so load/store execution and ROB retirement no longer depend on a single serialized LSU state machine. Use profile-guided gates after each task to ensure performance trends move toward the Phase 1 target.

**Tech Stack:** SystemVerilog RTL (`backend/execute/cache/retire`), C++ tests (`test_lsu/test_dcache/test_backend/test_triathlon`), profiler (`run_profile.sh` + `parse_profile.py`), Verilator build.

---

## Phase 1 Acceptance Targets (must all pass before phase close)
- CoreMark IPC: `>= 1.20`
- Dhrystone IPC: `>= 0.82`
- CoreMark:
  - `stall_category.other` share `<= 40%`
  - `stall_other_detail` sum of `rob_head_*_incomplete_nonbp + lsu_wait_wb_head_lsu_incomplete` reduced by `>= 45%` vs baseline
  - `decode_blocked.lsug_wait_dcache_owner + decode_blocked.lsug_no_free_lane` reduced by `>= 50%`

Baseline reference (frozen on 2026-02-21): `npc/build/profile/latest/summary.json`
- `coremark.ipc = 0.914309`
- `dhrystone.ipc = 0.789080`
- `coremark.stall_category.other / coremark.stall_total = 0.602539`
- `coremark_hol_incomplete_sum = 560529`
  - defined as `sum(rob_head_*_incomplete_nonbp) + lsu_wait_wb_head_lsu_incomplete`
- `coremark_decode_blocked_lsu_sum = 132936`
  - defined as `lsug_wait_dcache_owner + lsug_no_free_lane`

---

### Task 1: Freeze baseline and add Phase 1 score script

**Files:**
- Create: `npc/tools/profiler/check_phase1_targets.py`
- Modify: `docs/plans/2026-02-21-a6-phase1-backend-lsu-execution.md`

**Step 1: Write the failing score check (red)**

```python
# check_phase1_targets.py (initial)
# Read summary.json and fail unless ipc/stall targets are met.
```

**Step 2: Run to verify it fails on current baseline**

Run:
`python3 npc/tools/profiler/check_phase1_targets.py --summary npc/build/profile/latest/summary.json`

Expected: `FAIL` with unmet target messages.

**Step 3: Implement stable metric extraction + clear fail messages**

```python
# Parse coremark/dhrystone metrics and print per-target status.
```

**Step 4: Re-run and keep it red (intentional gate)**

Run:
`python3 npc/tools/profiler/check_phase1_targets.py --summary npc/build/profile/latest/summary.json`

Expected: still `FAIL`, but output is deterministic and readable.

**Step 5: Commit**

```bash
git add npc/tools/profiler/check_phase1_targets.py docs/plans/2026-02-21-a6-phase1-backend-lsu-execution.md
git commit -m "chore(profile): add phase1 backend/lsu performance gate script"
```

---

### Task 2: Introduce explicit LQ/SQ structures (no behavior change yet)

**Files:**
- Create: `npc/vsrc/backend/execute/lq.sv`
- Create: `npc/vsrc/backend/execute/sq.sv`
- Modify: `npc/vsrc/backend/execute/lsu_group.sv`
- Modify: `npc/vsrc/backend/backend.sv`
- Test: `npc/vsrc/test/tb_lsu.sv`
- Test: `npc/csrc/test_lsu.cpp`

**Step 1: Write failing tests for queue semantics (red)**

```cpp
// test_lsu.cpp
// Case A: enqueue 4 loads into LQ and observe occupancy.
// Case B: enqueue stores into SQ and verify ordered dequeue contract.
```

**Step 2: Run to verify failure**

Run:
`make -C npc -f Makefile_test TEST=test_lsu run`

Expected: `FAIL` (missing LQ/SQ module interfaces/behavior).

**Step 3: Add minimal LQ/SQ modules and wire occupancy/valid paths**

```systemverilog
// lq.sv / sq.sv
// parameterized depth, alloc, head valid, pop, flush clear.
```

**Step 4: Re-run targeted tests**

Run:
`make -C npc -f Makefile_test TEST=test_lsu run`

Expected: `PASS` for queue occupancy/order checks.

**Step 5: Commit**

```bash
git add npc/vsrc/backend/execute/lq.sv npc/vsrc/backend/execute/sq.sv npc/vsrc/backend/execute/lsu_group.sv npc/vsrc/backend/backend.sv npc/vsrc/test/tb_lsu.sv npc/csrc/test_lsu.cpp
git commit -m "feat(lsu): add explicit parameterized LQ/SQ skeleton"
```

---

### Task 3: Add store-to-load forwarding in SQ path

**Files:**
- Modify: `npc/vsrc/backend/execute/sq.sv`
- Modify: `npc/vsrc/backend/execute/lsu_group.sv`
- Modify: `npc/vsrc/cache/dcache.sv`
- Test: `npc/vsrc/test/tb_lsu.sv`
- Test: `npc/csrc/test_lsu.cpp`

**Step 1: Write failing forwarding tests (red)**

```cpp
// Store then younger load same line/overlapping byte lanes.
// Expect load to get forwarded data without waiting dcache response.
```

**Step 2: Run and confirm failure**

Run:
`make -C npc -f Makefile_test TEST=test_lsu run`

Expected: load reads stale/old value -> `FAIL`.

**Step 3: Implement byte-mask-aware forwarding lookup**

```systemverilog
// Search older committed-visible stores in SQ.
// Merge bytes from newest matching store.
```

**Step 4: Re-run tests**

Run:
`make -C npc -f Makefile_test TEST=test_lsu run`

Expected: `PASS` for forwarding cases.

**Step 5: Commit**

```bash
git add npc/vsrc/backend/execute/sq.sv npc/vsrc/backend/execute/lsu_group.sv npc/vsrc/cache/dcache.sv npc/vsrc/test/tb_lsu.sv npc/csrc/test_lsu.cpp
git commit -m "feat(lsu): implement store-to-load forwarding from SQ"
```

---

### Task 4: Speculative load bypass + violation replay

**Files:**
- Create: `npc/vsrc/backend/execute/mem_dep_predictor.sv`
- Modify: `npc/vsrc/backend/execute/lq.sv`
- Modify: `npc/vsrc/backend/execute/sq.sv`
- Modify: `npc/vsrc/backend/execute/lsu_group.sv`
- Modify: `npc/vsrc/backend/backend.sv`
- Modify: `npc/vsrc/backend/retire/rob.sv`
- Test: `npc/vsrc/test/tb_backend.sv`
- Test: `npc/csrc/test_backend.cpp`

**Step 1: Write failing violation tests (red)**

```cpp
// Younger load bypasses unresolved older store -> later detect addr conflict.
// Expect selective replay (load + dependent uops), not full-pipeline deadlock.
```

**Step 2: Run and verify failure**

Run:
`make -C npc -f Makefile_test TEST=test_backend run`

Expected: mismatch/replay missing -> `FAIL`.

**Step 3: Implement predictor + violation detector + replay injection**

```systemverilog
// predictor says bypass/no-bypass
// on store addr resolve, detect younger-load conflict
// emit replay request to backend/rename pending path
```

**Step 4: Re-run backend tests**

Run:
`make -C npc -f Makefile_test TEST=test_backend run`

Expected: `PASS` on replay semantics.

**Step 5: Commit**

```bash
git add npc/vsrc/backend/execute/mem_dep_predictor.sv npc/vsrc/backend/execute/lq.sv npc/vsrc/backend/execute/sq.sv npc/vsrc/backend/execute/lsu_group.sv npc/vsrc/backend/backend.sv npc/vsrc/backend/retire/rob.sv npc/vsrc/test/tb_backend.sv npc/csrc/test_backend.cpp
git commit -m "feat(lsu): add speculative load bypass with violation replay"
```

---

### Task 5: DCache parallelization (banking + deeper MSHR)

**Files:**
- Modify: `npc/vsrc/cache/dcache.sv`
- Modify: `npc/vsrc/cache/mshr.sv`
- Modify: `npc/vsrc/include/config_pkg.sv`
- Modify: `npc/vsrc/include/build_config_pkg.sv`
- Modify: `npc/vsrc/include/test_config_pkg.sv`
- Test: `npc/csrc/test_dcache.cpp`
- Test: `npc/vsrc/test/tb_lsu.sv`

**Step 1: Write failing tests for hit-under-miss + miss-under-miss (red)**

```cpp
// Case A: hit under outstanding miss should complete.
// Case B: 4+ independent misses accepted until MSHR full threshold.
```

**Step 2: Run and verify failure**

Run:
`make -C npc -f Makefile_test TEST=test_dcache run`

Expected: serialization bottleneck -> `FAIL`.

**Step 3: Implement banked access + configurable MSHR depth**

```systemverilog
parameter int unsigned DC_BANKS = 4;
parameter int unsigned DC_MSHR_DEPTH = 16;
```

**Step 4: Re-run cache + lsu tests**

Run:
- `make -C npc -f Makefile_test TEST=test_dcache run`
- `make -C npc -f Makefile_test TEST=test_lsu run`

Expected: both `PASS`.

**Step 5: Commit**

```bash
git add npc/vsrc/cache/dcache.sv npc/vsrc/cache/mshr.sv npc/vsrc/include/config_pkg.sv npc/vsrc/include/build_config_pkg.sv npc/vsrc/include/test_config_pkg.sv npc/csrc/test_dcache.cpp npc/vsrc/test/tb_lsu.sv
git commit -m "feat(dcache): add banked non-blocking path and deeper mshr"
```

---

### Task 6: ROB completion event queue (decouple head progress)

**Files:**
- Create: `npc/vsrc/backend/retire/completion_queue.sv`
- Modify: `npc/vsrc/backend/retire/rob.sv`
- Modify: `npc/vsrc/backend/backend.sv`
- Modify: `npc/vsrc/backend/retire/writeback.sv`
- Test: `npc/vsrc/test/tb_backend.sv`
- Test: `npc/csrc/test_backend.cpp`

**Step 1: Write failing test for non-HOL completion visibility (red)**

```cpp
// Younger ready entries should enqueue completion events while head waits LSU.
// When head becomes ready, retire should proceed immediately without extra bubbles.
```

**Step 2: Run and verify failure**

Run:
`make -C npc -f Makefile_test TEST=test_backend run`

Expected: head-only completion behavior causes fail.

**Step 3: Implement completion queue and ROB consume path**

```systemverilog
// enqueue completion tags from all FU paths
// rob marks complete via queue event, not direct coupled state only
```

**Step 4: Re-run backend tests**

Run:
`make -C npc -f Makefile_test TEST=test_backend run`

Expected: `PASS`.

**Step 5: Commit**

```bash
git add npc/vsrc/backend/retire/completion_queue.sv npc/vsrc/backend/retire/rob.sv npc/vsrc/backend/backend.sv npc/vsrc/backend/retire/writeback.sv npc/vsrc/test/tb_backend.sv npc/csrc/test_backend.cpp
git commit -m "feat(rob): add completion queue to decouple retirement from lsu state"
```

---

### Task 7: Integrate profiler observability for new LSU/ROB paths

**Files:**
- Modify: `npc/vsrc/test/tb_triathlon.sv`
- Modify: `npc/csrc/npc_main.cpp`
- Modify: `npc/tools/profiler/parse_profile.py`
- Modify: `npc/tools/profiler/tests/test_parse_profile.py`

**Step 1: Write failing parser tests for new detail buckets (red)**

```python
# New expected keys:
# rob_head_lsu_incomplete_wait_req_ready_nonbp
# rob_head_lsu_incomplete_wait_rsp_valid_nonbp
# rob_empty_refill_*
```

**Step 2: Run parser tests and verify failure**

Run:
`python3 -m unittest npc.tools.profiler.tests.test_parse_profile -v`

Expected: `FAIL` on missing keys.

**Step 3: Add runtime tags + parser/report support**

```cpp
// npc_main.cpp emits fine-grained stallm5 keys.
```

**Step 4: Re-run parser tests**

Run:
`python3 -m unittest npc.tools.profiler.tests.test_parse_profile -v`

Expected: `PASS`.

**Step 5: Commit**

```bash
git add npc/vsrc/test/tb_triathlon.sv npc/csrc/npc_main.cpp npc/tools/profiler/parse_profile.py npc/tools/profiler/tests/test_parse_profile.py
git commit -m "feat(profile): add lsu/rob fine-grained phase1 stall observability"
```

---

### Task 8: Full regression and Phase 1 performance gate

**Files:**
- Modify: `docs/plans/2026-02-21-a6-phase1-backend-lsu-execution.md`

**Step 1: Run full functional regression**

Run:
- `make -C npc -f Makefile_test run-all`
- `make -C am-kernels/tests/cpu-tests ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf- run`

Expected: all pass.

**Step 2: Run performance profile**

Run:
`make -C npc profile-report ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf- PROFILE_OUT_DIR=$(pwd)/npc/build/profile/latest`

Expected: `summary.json` and `report.md` generated.

**Step 3: Run phase gate script**

Run:
`python3 npc/tools/profiler/check_phase1_targets.py --summary npc/build/profile/latest/summary.json`

Expected: `PASS`.

**Step 4: If gate fails, run parameter sweep once and retry**

Run:
- adjust config knobs (`ROB/LQ/SQ/MSHR/DC_BANKS`)
- rerun profile + gate

Expected: gate `PASS`.

**Step 5: Commit**

```bash
git add docs/plans/2026-02-21-a6-phase1-backend-lsu-execution.md
git commit -m "docs(plan): close phase1 backend-lsu execution with verified targets"
```

---

## Commit slicing (recommended)
1. profiler gate script
2. LQ/SQ skeleton
3. forwarding
4. speculative bypass + replay
5. dcache banking + deeper mshr
6. completion queue + ROB integration
7. profiler observability
8. phase close docs

## Execution notes
- Keep behavior changes isolated per task; do not batch multiple architectural risks in one commit.
- If a task introduces difftest mismatch, stop and resolve before starting next task.
- Always re-profile after tasks 5/6/8; these are highest leverage for Phase 1 KPI movement.
