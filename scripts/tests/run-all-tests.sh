#!/usr/bin/env bash
#
# MSK Multi-Region Test Suite — Orchestrator
#
# Runs all multi-region tests in dependency order and reports results.
#
# Usage: ./scripts/tests/run-all-tests.sh [flags]
#
# Flags:
#   --stop-on-failure     Stop after the first test failure
#   --skip=<test>         Skip a specific test (repeatable)
#   --only=<test>         Run only a specific test (repeatable)
#
# Examples:
#   ./scripts/tests/run-all-tests.sh
#   ./scripts/tests/run-all-tests.sh --stop-on-failure
#   ./scripts/tests/run-all-tests.sh --skip=test-scaling --skip=test-regional-failure
#   ./scripts/tests/run-all-tests.sh --only=test-replication-baseline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Output helpers ──────────────────────────────────────────────
header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo -e "${CYAN}  $*${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"
}

info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET} $*"; }
pass()  { echo -e "${GREEN}[PASS]${RESET} $*"; }

die() {
    fail "$*"
    exit 1
}

# ─── Parse flags ─────────────────────────────────────────────────
STOP_ON_FAILURE=false
declare -a SKIP_TESTS=()
declare -a ONLY_TESTS=()

for arg in "$@"; do
    case "$arg" in
        --stop-on-failure)
            STOP_ON_FAILURE=true
            ;;
        --skip=*)
            SKIP_TESTS+=("${arg#--skip=}")
            ;;
        --only=*)
            ONLY_TESTS+=("${arg#--only=}")
            ;;
        --help|-h)
            echo "Usage: $0 [--stop-on-failure] [--skip=<test>] [--only=<test>]"
            echo ""
            echo "Flags:"
            echo "  --stop-on-failure     Stop after the first test failure"
            echo "  --skip=<test>         Skip a specific test (repeatable)"
            echo "  --only=<test>         Run only a specific test (repeatable)"
            echo ""
            echo "Test names (use without .sh extension):"
            echo "  test-replication-baseline"
            echo "  test-loop-prevention"
            echo "  test-consumer-groups"
            echo "  test-scaling"
            echo "  test-regional-failure"
            echo "  test-failover"
            echo "  test-failback"
            exit 0
            ;;
        *)
            die "Unknown argument: $arg (use --help for usage)"
            ;;
    esac
done

# ─── Test definitions ────────────────────────────────────────────
# Ordered by dependency: foundational tests first, destructive tests last
declare -a TEST_SCRIPTS=(
    "test-replication-baseline.sh"
    "test-loop-prevention.sh"
    "test-consumer-groups.sh"
    "test-scaling.sh"
    "test-regional-failure.sh"
    "test-failover.sh"
    "test-failback.sh"
)

declare -A TEST_LABELS=(
    [test-replication-baseline.sh]="Replication Baseline"
    [test-loop-prevention.sh]="Loop Prevention"
    [test-consumer-groups.sh]="Consumer Groups"
    [test-scaling.sh]="Scaling (KEDA + Karpenter)"
    [test-regional-failure.sh]="Regional Failure (FIS)"
    [test-failover.sh]="Failover"
    [test-failback.sh]="Failback"
)

# ─── Helpers ─────────────────────────────────────────────────────
is_skipped() {
    local script_name="$1"
    local test_name="${script_name%.sh}"

    # If --only is specified, skip everything not in the list
    if [[ ${#ONLY_TESTS[@]} -gt 0 ]]; then
        for only in "${ONLY_TESTS[@]}"; do
            only="${only%.sh}"
            if [[ "$test_name" == "$only" ]]; then
                return 1  # not skipped
            fi
        done
        return 0  # skipped (not in --only list)
    fi

    # Check --skip list
    for skip in "${SKIP_TESTS[@]}"; do
        skip="${skip%.sh}"
        if [[ "$test_name" == "$skip" ]]; then
            return 0  # skipped
        fi
    done

    return 1  # not skipped
}

# ─── Banner ──────────────────────────────────────────────────────
header "MSK Multi-Region Test Suite"
echo ""
info "Date: $(date '+%Y-%m-%d %H:%M:%S')"
if [[ "$STOP_ON_FAILURE" == "true" ]]; then
    info "Mode: stop on first failure"
fi
if [[ ${#SKIP_TESTS[@]} -gt 0 ]]; then
    info "Skipping: ${SKIP_TESTS[*]}"
fi
if [[ ${#ONLY_TESTS[@]} -gt 0 ]]; then
    info "Only running: ${ONLY_TESTS[*]}"
fi

# ─── Pre-flight: required tools ──────────────────────────────────
header "Pre-flight Checks"

REQUIRED_TOOLS=(kubectl aws helm python3)
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        info "$tool: $(command -v "$tool")"
    else
        MISSING_TOOLS+=("$tool")
        fail "$tool: not found"
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    die "Missing required tools: ${MISSING_TOOLS[*]}"
fi

info "All required tools available"

# Verify test scripts exist
MISSING_SCRIPTS=()
for script in "${TEST_SCRIPTS[@]}"; do
    if is_skipped "$script"; then
        continue
    fi
    if [[ ! -x "$SCRIPT_DIR/$script" ]]; then
        if [[ -f "$SCRIPT_DIR/$script" ]]; then
            warn "$script exists but is not executable — will try to run with bash"
        else
            MISSING_SCRIPTS+=("$script")
            fail "$script: not found in $SCRIPT_DIR"
        fi
    fi
done

if [[ ${#MISSING_SCRIPTS[@]} -gt 0 ]]; then
    warn "Missing test scripts: ${MISSING_SCRIPTS[*]}"
    warn "These tests will be marked as SKIP"
fi

# ─── Run tests ───────────────────────────────────────────────────
header "Running Tests"

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
SUITE_START=$(date +%s)

for script in "${TEST_SCRIPTS[@]}"; do
    label="${TEST_LABELS[$script]:-$script}"
    test_name="${script%.sh}"

    # Check if skipped
    if is_skipped "$script"; then
        RESULT_NAMES+=("$label")
        RESULT_STATUS+=("SKIP")
        SKIPPED=$((SKIPPED + 1))
        echo -e "  ${DIM}SKIP${RESET}  $label"
        continue
    fi

    # Check if script exists
    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        RESULT_NAMES+=("$label")
        RESULT_STATUS+=("SKIP")
        SKIPPED=$((SKIPPED + 1))
        echo -e "  ${DIM}SKIP${RESET}  $label (not found)"
        continue
    fi

    TOTAL=$((TOTAL + 1))
    echo ""
    echo -e "${BOLD}── Running: $label ──${RESET}"
    echo ""

    TEST_START=$(date +%s)
    EXIT_CODE=0

    # Run the test script
    if [[ -x "$SCRIPT_DIR/$script" ]]; then
        "$SCRIPT_DIR/$script" || EXIT_CODE=$?
    else
        bash "$SCRIPT_DIR/$script" || EXIT_CODE=$?
    fi

    TEST_DURATION=$(( $(date +%s) - TEST_START ))

    if [[ "$EXIT_CODE" -eq 0 ]]; then
        RESULT_NAMES+=("$label")
        RESULT_STATUS+=("PASS")
        PASSED=$((PASSED + 1))
        echo ""
        pass "$label completed in ${TEST_DURATION}s"
    else
        RESULT_NAMES+=("$label")
        RESULT_STATUS+=("FAIL")
        FAILED=$((FAILED + 1))
        echo ""
        fail "$label failed (exit code $EXIT_CODE) after ${TEST_DURATION}s"

        if [[ "$STOP_ON_FAILURE" == "true" ]]; then
            warn "Stopping due to --stop-on-failure"
            # Mark remaining tests as skipped
            REMAINING=false
            for remaining_script in "${TEST_SCRIPTS[@]}"; do
                if [[ "$REMAINING" == "true" ]]; then
                    remaining_label="${TEST_LABELS[$remaining_script]:-$remaining_script}"
                    if ! is_skipped "$remaining_script"; then
                        RESULT_NAMES+=("$remaining_label")
                        RESULT_STATUS+=("SKIP")
                        SKIPPED=$((SKIPPED + 1))
                    fi
                fi
                if [[ "$remaining_script" == "$script" ]]; then
                    REMAINING=true
                fi
            done
            break
        fi
    fi
done

SUITE_DURATION=$(( $(date +%s) - SUITE_START ))

# ─── Summary table ───────────────────────────────────────────────
header "Test Suite Results"

echo ""
printf "  ${BOLD}%-35s %s${RESET}\n" "Test" "Result"
echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"

for i in "${!RESULT_NAMES[@]}"; do
    name="${RESULT_NAMES[$i]}"
    status="${RESULT_STATUS[$i]}"

    case "$status" in
        PASS) color="$GREEN" ;;
        FAIL) color="$RED" ;;
        SKIP) color="$DIM" ;;
        *)    color="$RESET" ;;
    esac

    printf "  %-35s ${color}%s${RESET}\n" "$name" "$status"
done

echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"
echo ""
echo -e "  Total: ${BOLD}$TOTAL${RESET}  Passed: ${GREEN}$PASSED${RESET}  Failed: ${RED}$FAILED${RESET}  Skipped: ${DIM}$SKIPPED${RESET}"
echo -e "  Duration: ${SUITE_DURATION}s"
echo ""

# ─── Exit code ───────────────────────────────────────────────────
if [[ "$FAILED" -gt 0 ]]; then
    fail "$FAILED test(s) failed"
    exit 1
fi

pass "All tests passed"
exit 0
