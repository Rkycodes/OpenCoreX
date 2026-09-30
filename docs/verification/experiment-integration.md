# Experiment integration verification — 2026-09-30

Initial WSL checkout was clean on `feat/pim-cold-warm-timing`; ignored build
artifacts were preserved. Origin: `https://github.com/Rkycodes/OpenCoreX.git`.
After fetching, main remained `93c2581`, CPU diagnostics `8cdef7a`,
cold/warm `ab55d93`. No worktree was needed.

Integration branch: `codex/integrate-matvec-experiments`. Both fetched
experiments were merged. The four shared files retain both targets,
documentation entries, and both focused tests under test/verify.
Production RTL and measured assertions were unchanged.

Commands in Ubuntu WSL at `/home/robel/OpenCoreX`:

```bash
git status --short
git branch --show-current
git remote -v
git fetch --all --prune
git branch -avv
git diff origin/main...origin/feat/cpu-matvec-diagnostics --stat
git diff origin/main...origin/feat/pim-cold-warm-timing --stat
git switch -c codex/integrate-matvec-experiments origin/main
git merge --no-ff origin/feat/cpu-matvec-diagnostics -m "Merge CPU matvec diagnostics"
git merge --no-ff origin/feat/pim-cold-warm-timing -m "Merge PIM cold/warm diagnostics"
# Resolve four shared files retaining both experiments.
bash -n scripts/verify.sh
python3 scripts/generate_matvec_diagnostics.py
python3 scripts/generate_pim_cold_warm_1x16_16x32.py
git diff --exit-code -- programs/hex
git diff --check
make diagnostics > /tmp/opencorex-diagnostics.log 2>&1
make cold-warm > /tmp/opencorex-cold-warm.log 2>&1
make verify > /tmp/opencorex-verify.log 2>&1
```

All passed with WSL Verilator `5.032 2025-01-01 rev (Debian 5.032-1)`.
Images were unchanged. The full gate passed RTL lint, 33 positive benches,
four diagnostic configurations, and all expected-failure cases.
CPU cycles: looped 23,685, streaming 13,290, resident 9,818, all on both
direct/subsystem paths. Offload: 4,272 whole program, 4,141 execution,
25 CPU fetches. Two-command PIM: 8,452 whole program, cold/warm 4,141/4,140,
vector reads 16/0, matrix reads 512/512, output writes 32/32.
See the [comparison contract](../evaluation/comparison-contract.md).

The scratch Verilator 5.020 PCH error was not reproduced in the actual
WSL gate; no compiler workaround or assertion change was needed.
