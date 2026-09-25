#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/obj_dir/verification"

readonly SCRIPT_DIR
readonly REPO_ROOT
readonly BUILD_ROOT

readonly -a POSITIVE_TESTS=(
    alu_decoder_tb
    alu_tb
    controller_tb
    cpu_address_router_tb
    datapath_tb
    immediate_generator_tb
    memory_init_tb
    memory_tb
    register_file_tb
    memory_interconnect_tb
    synchronous_memory_adapter_tb
    memory_subsystem_tb
    opencorex_core_tb
    opencorex_mul_tb
    opencorex_dot_product_tb
    opencorex_matvec_tb
    opencorex_corner_cases_tb
    opencorex_illegal_tb
    opencorex_reset_tb
    opencorex_memory_subsystem_tb
    opencorex_matvec_subsystem_tb
)

cd "$REPO_ROOT"

# Prevent expected $fatal tests from creating core-dump files.
ulimit -c 0 || true

print_section() {
    printf '\n===== %s =====\n' "$1"
}

fail() {
    printf '\nFAIL: %s\n' "$1" >&2
    exit 1
}

check_dependencies() {
    local tool

    for tool in verilator make c++; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "required tool '$tool' was not found"
        fi
    done

    printf 'Using %s\n' "$(verilator --version)"
}

run_lint() {
    print_section "CPU RTL lint"

    verilator --lint-only -Wall \
        --top-module opencorex_core \
        rtl/alu.sv \
        rtl/alu_decoder.sv \
        rtl/controller.sv \
        rtl/datapath.sv \
        rtl/immediate_generator.sv \
        rtl/opencorex_core.sv \
        rtl/register_file.sv

    print_section "Memory RTL lint"

    verilator --lint-only -Wall \
        --top-module memory \
        rtl/memory.sv

    print_section "Memory interconnect RTL lint"

    verilator --lint-only -Wall \
        --top-module memory_interconnect \
        rtl/memory_interconnect.sv

    print_section "CPU address router RTL lint"

    verilator --lint-only -Wall \
        --top-module cpu_address_router \
        -GRAM_WORDS=1024 \
        rtl/cpu_address_router.sv

    print_section "Synchronous memory adapter RTL lint"

    verilator --lint-only -Wall \
        --top-module synchronous_memory_adapter \
        rtl/synchronous_memory_adapter.sv

    print_section "OpenCoreX memory subsystem RTL lint"

    verilator --lint-only -Wall \
        --top-module opencorex_memory_subsystem \
        rtl/alu.sv \
        rtl/alu_decoder.sv \
        rtl/controller.sv \
        rtl/datapath.sv \
        rtl/immediate_generator.sv \
        rtl/memory_interconnect.sv \
        rtl/opencorex_core.sv \
        rtl/opencorex_memory_subsystem.sv \
        rtl/register_file.sv \
        rtl/synchronous_memory_adapter.sv

    printf '\nPASS: RTL lint completed\n'
}

run_positive_tests() {
    local test_name
    local testbench
    local test_build
    local executable

    mkdir -p "$BUILD_ROOT"

    for test_name in "${POSITIVE_TESTS[@]}"; do
        testbench="tb/${test_name}.sv"
        test_build="$BUILD_ROOT/$test_name"
        executable="$test_build/V${test_name}"

        if [[ ! -f "$testbench" ]]; then
            fail "missing testbench: $testbench"
        fi

        print_section "$test_name"

        verilator --binary --timing -Wall \
            --top-module "$test_name" \
            --Mdir "$test_build" \
            rtl/*.sv \
            "$testbench"

        "$executable"
    done

    printf '\nPASS: all %d positive testbenches completed\n' \
        "${#POSITIVE_TESTS[@]}"
}

run_expected_failure() {
    local executable="$1"
    local test_number="$2"
    local expected_message="$3"
    local log_file="$BUILD_ROOT/memory_error_${test_number}.log"
    local status

    print_section "memory_error_tb TEST=$test_number"

    if "$executable" "+TEST=$test_number" >"$log_file" 2>&1; then
        status=0
    else
        status=$?
    fi

    cat "$log_file"

    if [[ "$status" -eq 0 ]]; then
        fail "memory_error_tb TEST=$test_number unexpectedly succeeded"
    fi

    if ! grep -Fq "$expected_message" "$log_file"; then
        fail "memory_error_tb TEST=$test_number produced the wrong failure"
    fi

    printf 'PASS: TEST=%s failed for the expected reason\n' \
        "$test_number"
}

run_expected_failure_tests() {
    local test_build="$BUILD_ROOT/memory_error_tb"
    local executable="$test_build/Vmemory_error_tb"
    local status

    mkdir -p "$BUILD_ROOT"

    print_section "Build memory_error_tb"

    verilator --binary --timing -Wall \
        --top-module memory_error_tb \
        --Mdir "$test_build" \
        rtl/memory.sv \
        tb/memory_error_tb.sv

    run_expected_failure \
        "$executable" \
        1 \
        "ILLEGAL: READ and WRITE are asserted simultaneously"

    run_expected_failure \
        "$executable" \
        2 \
        "ILLEGAL: misaligned memory address 00000002"

    run_expected_failure \
        "$executable" \
        3 \
        "ILLEGAL: memory address out of range: 00001000"

    test_build="$BUILD_ROOT/cpu_address_router_tb"
    executable="$test_build/Vcpu_address_router_tb"

    print_section "Build cpu_address_router_tb"

    verilator --binary --timing -Wall \
        --top-module cpu_address_router_tb \
        --Mdir "$test_build" \
        rtl/cpu_address_router.sv \
        tb/cpu_address_router_tb.sv

    print_section "cpu_address_router_tb TEST=unmapped"

    if "$executable" "+TEST=unmapped" \
            >"$BUILD_ROOT/cpu_address_router_unmapped.log" 2>&1; then
        status=0
    else
        status=$?
    fi

    cat "$BUILD_ROOT/cpu_address_router_unmapped.log"

    if [[ "$status" -eq 0 ]]; then
        fail "cpu_address_router_tb TEST=unmapped unexpectedly succeeded"
    fi

    if ! grep -Fq "ILLEGAL: unmapped CPU address 00000040" \
            "$BUILD_ROOT/cpu_address_router_unmapped.log"; then
        fail "cpu_address_router_tb TEST=unmapped produced the wrong failure"
    fi

    printf 'PASS: router unmapped request failed for the expected reason\n'

    printf '\nPASS: all expected-failure tests completed\n'
}

clean_builds() {
    if [[ "$BUILD_ROOT" != "$REPO_ROOT/obj_dir/verification" ]]; then
        fail "refusing to remove unexpected build path: $BUILD_ROOT"
    fi

    if [[ -d "$BUILD_ROOT" ]]; then
        rm -rf -- "$BUILD_ROOT"
    fi

    printf 'Removed automated verification builds\n'
}

command_name="${1:-verify}"

case "$command_name" in
    lint)
        check_dependencies
        run_lint
        ;;

    test)
        check_dependencies
        run_positive_tests
        ;;

    test-errors)
        check_dependencies
        run_expected_failure_tests
        ;;

    verify)
        check_dependencies
        run_lint
        run_positive_tests
        run_expected_failure_tests
        printf '\n========================================\n'
        printf 'PASS: OpenCoreX verification completed\n'
        printf '========================================\n'
        ;;

    clean)
        clean_builds
        ;;

    help|--help|-h)
        printf 'Usage: %s {lint|test|test-errors|verify|clean}\n' "$0"
        ;;

    *)
        fail "unknown command: $command_name"
        ;;
esac
