#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Automated Test Suite
# tests/test_suite.sh
#
# Regression and unit verification test harness for all scripts and libraries.
# Executable without external dependencies in any standard Bash environment.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Colors for terminal output
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;34m'
C_RESET='\033[0m'

test_start() {
    TEST_COUNT=$(( TEST_COUNT + 1 ))
    printf "${C_BLUE}[TEST %02d]${C_RESET} %s ... " "${TEST_COUNT}" "$1"
}

assert_pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "${C_GREEN}PASS${C_RESET}\n"
}

assert_fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "${C_RED}FAIL${C_RESET} (%s)\n" "$1"
}

# Temporary directory for test execution
TEST_TMP=$(mktemp -d -t test-suite-XXXXXX)
cleanup() {
    rm -rf "${TEST_TMP}"
}
trap cleanup EXIT INT TERM

printf "\n${C_YELLOW}========================================${C_RESET}\n"
printf "${C_YELLOW} Running Linux Admin Scripts Test Suite ${C_RESET}\n"
printf "${C_YELLOW}========================================${C_RESET}\n\n"

# ------------------------------------------------------------------------------
# Test 1: Bash Syntax Validation (bash -n)
# ------------------------------------------------------------------------------
test_start "Bash syntax verification (bash -n) on all scripts"
SYNTAX_FAIL=0
for script in "${PROJECT_ROOT}"/bin/*.sh "${PROJECT_ROOT}"/lib/*.sh; do
    if [[ -f "${script}" ]]; then
        if ! bash -n "${script}" 2>/dev/null; then
            SYNTAX_FAIL=1
            break
        fi
    fi
done

if (( SYNTAX_FAIL == 0 )); then
    assert_pass
else
    assert_fail "Syntax error detected in one of the shell scripts"
fi

# ------------------------------------------------------------------------------
# Test 2: lib/logger.sh unit verification
# ------------------------------------------------------------------------------
test_start "lib/logger.sh level filtering and output formatting"
# shellcheck source=lib/logger.sh
source "${PROJECT_ROOT}/lib/logger.sh"

INFO_OUT=$(log_info "Test info message")
if [[ "${INFO_OUT}" == *"INFO"*"Test info message"* ]]; then
    assert_pass
else
    assert_fail "Unexpected log_info output format: '${INFO_OUT}'"
fi

# ------------------------------------------------------------------------------
# Test 3: lib/notify.sh fallback when webhook is unconfigured
# ------------------------------------------------------------------------------
test_start "lib/notify.sh graceful fallback with unconfigured webhook"
# shellcheck source=lib/notify.sh
source "${PROJECT_ROOT}/lib/notify.sh"

if WEBHOOK_URL="" send_notification "Test Title" "Test Body" "INFO" ""; then
    assert_pass
else
    assert_fail "send_notification failed when webhook was unconfigured"
fi

# ------------------------------------------------------------------------------
# Test 4: bin/backup-engine.sh dry-run execution
# ------------------------------------------------------------------------------
test_start "bin/backup-engine.sh dry-run execution (-n)"
MOCK_BACKUP_SRC="${TEST_TMP}/backup_src"
mkdir -p "${MOCK_BACKUP_SRC}"
echo "sample data" > "${MOCK_BACKUP_SRC}/data.txt"

if bash "${PROJECT_ROOT}/bin/backup-engine.sh" -s "${MOCK_BACKUP_SRC}" -d "${TEST_TMP}/backups" -n >/dev/null 2>&1; then
    assert_pass
else
    assert_fail "backup-engine.sh dry run failed"
fi

# ------------------------------------------------------------------------------
# Test 5: bin/backup-engine.sh full archival and checksum validation
# ------------------------------------------------------------------------------
test_start "bin/backup-engine.sh archive creation and SHA-256 validation"
MOCK_DEST="${TEST_TMP}/backup_dest"
mkdir -p "${MOCK_DEST}"

if bash "${PROJECT_ROOT}/bin/backup-engine.sh" -s "${MOCK_BACKUP_SRC}" -d "${MOCK_DEST}" -r 1 >/dev/null 2>&1; then
    ARCHIVE_FILE=$(find "${MOCK_DEST}" -maxdepth 1 -name "backup-*.tar.gz" | head -n 1)
    if [[ -n "${ARCHIVE_FILE}" && -f "${ARCHIVE_FILE}.sha256" ]]; then
        # Verify checksum matches
        if (cd "${MOCK_DEST}" && sha256sum -c "$(basename "${ARCHIVE_FILE}").sha256" --status); then
            assert_pass
        else
            assert_fail "SHA-256 checksum verification failed"
        fi
    else
        assert_fail "Archive or checksum file missing"
    fi
else
    assert_fail "backup-engine.sh execution failed"
fi

# ------------------------------------------------------------------------------
# Test 6: bin/sys-health.sh structured JSON output
# ------------------------------------------------------------------------------
test_start "bin/sys-health.sh structured JSON telemetry output (-j)"
HEALTH_JSON=$(bash "${PROJECT_ROOT}/bin/sys-health.sh" -j 2>/dev/null || true)

if [[ "${HEALTH_JSON}" == *"\"status\":"* && "${HEALTH_JSON}" == *"\"cpu_pct\":"* && "${HEALTH_JSON}" == *"\"mem_pct\":"* ]]; then
    assert_pass
else
    assert_fail "Invalid JSON output from sys-health.sh: '${HEALTH_JSON}'"
fi

# ------------------------------------------------------------------------------
# Test 7: bin/log-manager.sh incident pattern analyzer (-a)
# ------------------------------------------------------------------------------
test_start "bin/log-manager.sh pattern analysis mode (-a)"
MOCK_LOG="${TEST_TMP}/access.log"
cat <<EOF > "${MOCK_LOG}"
192.168.1.10 - - [03/Oct/2026:12:00:01 +0000] "GET /api/v1/users HTTP/1.1" 200 452
192.168.1.15 - - [03/Oct/2026:12:00:02 +0000] "POST /api/v1/auth HTTP/1.1" 500 120
[ERROR] Database connection timeout: 192.168.1.15
[CRITICAL] Kernel out of memory condition simulated
EOF

LOG_ANALYSIS=$(bash "${PROJECT_ROOT}/bin/log-manager.sh" -l "${MOCK_LOG}" -a 2>&1 || true)
if [[ "${LOG_ANALYSIS}" == *"CRITICAL / FATAL"* && "${LOG_ANALYSIS}" == *"ERROR / FAILED"* ]]; then
    assert_pass
else
    assert_fail "log-manager.sh analysis failed to detect error signatures"
fi

# ------------------------------------------------------------------------------
# Test 8: bin/provision-user.sh dry-run simulation
# ------------------------------------------------------------------------------
test_start "bin/provision-user.sh dry-run validation (-n)"
if bash "${PROJECT_ROOT}/bin/provision-user.sh" -u "testdummy" -n >/dev/null 2>&1; then
    assert_pass
else
    assert_fail "provision-user.sh dry run failed"
fi

# ------------------------------------------------------------------------------
# Test 9: bin/web-deploy.sh test mode simulation
# ------------------------------------------------------------------------------
test_start "bin/web-deploy.sh dry-run test mode (-t)"
if bash "${PROJECT_ROOT}/bin/web-deploy.sh" -d "testsite.local" -t >/dev/null 2>&1; then
    assert_pass
else
    assert_fail "web-deploy.sh test mode failed"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf "\n${C_YELLOW}----------------------------------------${C_RESET}\n"
printf "Results: %d Total | ${C_GREEN}%d Passed${C_RESET} | ${C_RED}%d Failed${C_RESET}\n" "${TEST_COUNT}" "${PASS_COUNT}" "${FAIL_COUNT}"
printf "${C_YELLOW}----------------------------------------${C_RESET}\n\n"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
