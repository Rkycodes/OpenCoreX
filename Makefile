.DEFAULT_GOAL := verify

VERIFY_SCRIPT := ./scripts/verify.sh

.PHONY: help latency-sweep diagnostics cold-warm lint test test-errors verify clean

help:
	@echo "  make mac-study    Measure MAC fusion for square GEMM"
	@echo "  make mac-plot     Plot the recorded MAC study"
	@echo "OpenCoreX verification targets:"
	@echo "  make gemm-large-study Run 64x64 and 128x128 matrix multiplication"
	@echo "  make gemm-large-check Check recorded larger GEMM evidence"
	@echo "  make gemm-large-audit Audit saved larger GEMM results without simulation"
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

.PHONY: gemm-large-study gemm-large-check gemm-large-audit
gemm-large-study:
	@python3 scripts/run_gemm_large.py

gemm-large-check:
	@python3 scripts/run_gemm_large.py --check

gemm-large-audit:
	@python3 scripts/check_gemm_large_records.py

.PHONY: mac-study mac-plot
mac-study:
	@python3 scripts/run_mac_study.py

mac-plot:
	@python3 scripts/plot_mac.py

.PHONY: conv1-proof conv1-study conv1-plot conv1-audit
conv1-proof:
	@python3 scripts/generate_conv1.py
	@python3 scripts/conv1_trace.py

conv1-study:
	@python3 scripts/run_conv1_study.py

conv1-plot:
	@python3 scripts/plot_conv1.py

conv1-audit:
	@python3 scripts/run_conv1_study.py --audit
