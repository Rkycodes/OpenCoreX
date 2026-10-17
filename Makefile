.DEFAULT_GOAL := verify

VERIFY_SCRIPT := ./scripts/verify.sh

.PHONY: help latency-sweep diagnostics cold-warm lint test test-errors verify clean

help:
	@echo "OpenCoreX verification targets:"
	@echo "  make gemm-study   Run 16x16 and 32x32 matrix-matrix verification"
	@echo "  make gemm-check   Check recorded matrix-matrix evidence"
	@echo "  make tiling-study Run the 120-case larger-vector comparison"
	@echo "  make tiling-check Check recorded larger-vector evidence"
	@echo "  make scaling-study Run the 60-case output-count comparison"
	@echo "  make scaling-check Check recorded output-count evidence"
	@echo "  make cache-study  Run the 20-case instruction-cache comparison"
	@echo "  make latency-sweep Run both matched memory latency policies"
	@echo "  make lint         Run RTL lint"
	@echo "  make diagnostics  Run the four CPU diagnostic benchmarks"
	@echo "  make cold-warm    Run the focused PIM cold/warm benchmark"
	@echo "  make test         Run positive testbenches"
	@echo "  make test-errors  Run expected-failure memory tests"
	@echo "  make verify       Run the complete verification suite"
	@echo "  make clean        Remove automated verification builds"

cold-warm:
	@$(VERIFY_SCRIPT) cold-warm

lint:
	@$(VERIFY_SCRIPT) lint

latency-sweep:
	@python3 scripts/run_memory_latency_sweep.py

diagnostics:
	@$(VERIFY_SCRIPT) diagnostics

test:
	@$(VERIFY_SCRIPT) test

test-errors:
	@$(VERIFY_SCRIPT) test-errors

verify:
	@$(VERIFY_SCRIPT) verify

clean:
	@$(VERIFY_SCRIPT) clean

.PHONY: cache-study
cache-study:
	@python3 scripts/run_cache_study.py

.PHONY: scaling-study scaling-check
scaling-study:
	@python3 scripts/run_scaling_study.py

scaling-check:
	@python3 scripts/run_scaling_study.py --check

.PHONY: tiling-study tiling-check
tiling-study:
	@python3 scripts/run_tiling_study.py

tiling-check:
	@python3 scripts/run_tiling_study.py --check

.PHONY: gemm-study gemm-check
gemm-study:
	@python3 scripts/run_gemm_study.py

gemm-check:
	@python3 scripts/run_gemm_study.py --check
