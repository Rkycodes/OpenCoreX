.DEFAULT_GOAL := verify

VERIFY_SCRIPT := ./scripts/verify.sh

.PHONY: help lint test test-errors verify clean

help:
	@echo "OpenCoreX verification targets:"
	@echo "  make lint         Run RTL lint"
	@echo "  make test         Run positive testbenches"
	@echo "  make test-errors  Run expected-failure memory tests"
	@echo "  make verify       Run the complete verification suite"
	@echo "  make clean        Remove automated verification builds"

lint:
	@$(VERIFY_SCRIPT) lint

test:
	@$(VERIFY_SCRIPT) test

test-errors:
	@$(VERIFY_SCRIPT) test-errors

verify:
	@$(VERIFY_SCRIPT) verify

clean:
	@$(VERIFY_SCRIPT) clean
