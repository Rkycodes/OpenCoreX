.DEFAULT_GOAL := verify

VERIFY_SCRIPT := ./scripts/verify.sh

.PHONY: help diagnostics lint test test-errors verify clean

help:
	@echo "OpenCoreX verification targets:"
	@echo "  make lint         Run RTL lint"
	@echo "  make diagnostics  Run the four CPU diagnostic benchmarks"
	@echo "  make test         Run positive testbenches"
	@echo "  make test-errors  Run expected-failure memory tests"
	@echo "  make verify       Run the complete verification suite"
	@echo "  make clean        Remove automated verification builds"

lint:
	@$(VERIFY_SCRIPT) lint

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
