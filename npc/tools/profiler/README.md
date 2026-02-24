# NPC Profiler Workflow

## One-command run

```bash
make -C npc profile-report ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf-
```

Default output directory:

- `npc/build/profile/<timestamp>/summary.json`
- `npc/build/profile/<timestamp>/report.md`
- raw logs: `dhrystone.log`, `coremark.log`, `coremark_commit_sample.log`

If you want a fixed output directory (for example `latest`), override it:

```bash
make -C npc profile-report ARCH=riscv32e-npc CROSS_COMPILE=riscv64-elf- \
  PROFILE_OUT_DIR=$(pwd)/npc/build/profile/latest
```

## Parse existing logs only

```bash
make -C npc profile-parse PROFILE_OUT_DIR=/abs/path/to/profile-dir
```

## Notes

- This workflow does not modify CPU behavior; it only runs benchmarks and parses logs.
- `coremark_commit_sample.log` uses `--max-cycles=2000000` for manageable commit-trace size.
