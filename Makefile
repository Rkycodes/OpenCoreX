.DEFAULT_GOAL := verify

VERIFY_SCRIPT := ./scripts/verify.sh

.PHONY: help latency-sweep diagnostics cold-warm lint test test-errors verify clean

help:
	@echo "OpenCoreX verification targets:"
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
