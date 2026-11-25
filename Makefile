.DEFAULT_GOAL := verify

VERIFY_SCRIPT := ./scripts/verify.sh

.PHONY: help latency-sweep diagnostics cold-warm lint test test-errors verify clean

help:
	@echo "Verification:"
	@echo "  make verify / lint / test / test-errors"
	@echo "  make cold-warm / diagnostics / clean"
	@echo "Convolution:"
	@echo "  make cifar-conv1-study"
	@echo "  make conv1-study / conv1-audit / conv1-proof / conv1-plot"
	@echo "  make conv1-weight-reuse-study / conv1-weight-reuse-audit"
	@echo "  make conv1-weight-reuse-proof / conv1-weight-reuse-plot"
	@echo "Matrix benchmarks:"
	@echo "  make gemm-study / gemm-check / gemm-large-study / gemm-large-check"
	@echo "  make gemm-large-audit / mac-study / mac-plot"
	@echo "  make tiling-study / tiling-check / scaling-study / scaling-check"
	@echo "  make cache-study / latency-sweep"
	@echo "See docs/evaluation/README.md for workloads and CIFAR sweep commands."

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

.PHONY: conv1-weight-reuse-proof conv1-weight-reuse-study conv1-weight-reuse-plot conv1-weight-reuse-audit
conv1-weight-reuse-proof:
	@python3 scripts/conv1_weight_reuse_trace.py
	@python3 scripts/generate_conv1_weight_reuse.py --check

conv1-weight-reuse-study:
	@python3 scripts/run_conv1_weight_reuse.py

conv1-weight-reuse-plot:
	@python3 scripts/plot_conv1_weight_reuse.py

conv1-weight-reuse-audit:
	@python3 scripts/run_conv1_weight_reuse.py --audit

.PHONY: cifar-conv1-study
cifar-conv1-study:
	@python3 scripts/run_cifar_conv1.py
