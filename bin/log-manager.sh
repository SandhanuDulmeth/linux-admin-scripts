#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Log Manager & Incident Analyzer
# bin/log-manager.sh
#
# Production log rotation, retention enforcement, gzip compression, and
# rapid incident pattern analysis (error aggregation, IP frequency, HTTP errors).
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Locate Dependencies
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source Configuration
if [[ -f "${PROJECT_ROOT}/config/alerts.conf" ]]; then
    # shellcheck source=config/alerts.conf
    source "${PROJECT_ROOT}/config/alerts.conf"
elif [[ -f "/etc/linux-admin-scripts/alerts.conf" ]]; then
    # shellcheck source=/dev/null
    source "/etc/linux-admin-scripts/alerts.conf"
fi

# Source Libraries
if [[ -f "${PROJECT_ROOT}/lib/logger.sh" ]]; then
    # shellcheck source=lib/logger.sh
    source "${PROJECT_ROOT}/lib/logger.sh"
    # shellcheck source=lib/notify.sh
    source "${PROJECT_ROOT}/lib/notify.sh"
elif [[ -f "/usr/local/lib/linux-admin-scripts/logger.sh" ]]; then
    # shellcheck source=/dev/null
    source "/usr/local/lib/linux-admin-scripts/logger.sh"
    # shellcheck source=/dev/null
    source "/usr/local/lib/linux-admin-scripts/notify.sh"
else
    echo "ERROR: Required libraries (logger.sh, notify.sh) could not be located." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Default Settings
# ------------------------------------------------------------------------------
TARGET_LOG=""
MAX_SIZE_MB="${LOG_ROTATION_SIZE_MB:-50}"
RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"
COMPRESS_ARCHIVES=true
ANALYZE_MODE=false
DRY_RUN=false

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -l <log_path> [OPTIONS]

Manages log file lifecycles with copytruncate rotation, compression, and analysis.

Required:
  -l <path>     Path to the active log file to rotate, prune, or analyze

Options:
  -s <megabytes> Size threshold before rotating active log (Default: ${MAX_SIZE_MB}MB)
  -r <days>      Retention threshold for rotated archives (Default: ${RETENTION_DAYS} days)
  -a             Analyze mode: scan file for top errors, IPs, and HTTP failure codes
  -c             Compress rotated files with gzip (Default: true)
  -n             Dry run mode (simulate rotation and pruning without modifying files)
  -v             Verbose / debug output
  -h             Show this help text

Examples:
  $(basename "$0") -l /var/log/nginx/access.log -a
  $(basename "$0") -l /var/log/app/backend.log -s 100 -r 30
  $(basename "$0") -l /var/log/syslog -n
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while getopts "l:s:r:acnvh" opt; do
    case "${opt}" in
        l) TARGET_LOG="${OPTARG}" ;;
        s) MAX_SIZE_MB="${OPTARG}" ;;
        r) RETENTION_DAYS="${OPTARG}" ;;
        a) ANALYZE_MODE=true ;;
        c) COMPRESS_ARCHIVES=true ;;
        n) DRY_RUN=true ;;
        v) LOG_LEVEL="DEBUG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "${TARGET_LOG}" ]]; then
    log_error "Missing required argument: -l <log_path>"
    usage
fi

if [[ ! -f "${TARGET_LOG}" ]]; then
    log_error "Target log file not found: '${TARGET_LOG}'"
    exit 1
fi

if ! [[ "${MAX_SIZE_MB}" =~ ^[0-9]+$ ]]; then
    log_error "Max size (-s) must be a positive integer. Got: '${MAX_SIZE_MB}'"
    exit 1
fi

if ! [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
    log_error "Retention days (-r) must be a positive integer. Got: '${RETENTION_DAYS}'"
    exit 1
fi

LOG_BASENAME="$(basename "${TARGET_LOG}")"
LOG_DIR="$(dirname "${TARGET_LOG}")"

# ------------------------------------------------------------------------------
# Log Incident Pattern Analysis (-a)
# ------------------------------------------------------------------------------
run_analysis() {
    log_header "Log Incident Pattern Analysis: ${LOG_BASENAME}"

    local total_lines
    total_lines=$(wc -l < "${TARGET_LOG}" | awk '{print $1}')
    local file_size
    file_size=$(du -sh "${TARGET_LOG}" | awk '{print $1}')

    log_info "Analyzed File:  ${TARGET_LOG}"
    log_info "Total Lines:    ${total_lines}"
    log_info "Current Size:   ${file_size}"

    # Error Level Frequency
    log_header "Error Severity Counts"
    local error_count fatal_count warn_count
    error_count=$(grep -cEi 'error|exception|fail' "${TARGET_LOG}" || true)
    fatal_count=$(grep -cEi 'fatal|critical|panic' "${TARGET_LOG}" || true)
    warn_count=$(grep -cEi 'warn|warning' "${TARGET_LOG}" || true)

    printf "  • CRITICAL / FATAL : %d occurrences\n" "${fatal_count}"
    printf "  • ERROR / FAILED   : %d occurrences\n" "${error_count}"
    printf "  • WARN / WARNING   : %d occurrences\n" "${warn_count}"

    # Top 5 Distinct Error Patterns
    log_header "Top 5 Recurring Error Signatures"
    local error_patterns
    error_patterns=$(grep -Ei 'error|exception|fail|fatal|critical' "${TARGET_LOG}" 2>/dev/null \
        | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/[TIMESTAMP]/g' \
        | head -n 5000 \
        | sort | uniq -c | sort -rn | head -n 5 || true)

    if [[ -n "${error_patterns}" ]]; then
        echo "${error_patterns}" | awk '{ count=$1; $1=""; printf "  [%d times] %s\n", count, substr($0, 2) }'
    else
        log_info "No prominent error signatures detected."
    fi

    # Top 5 IP Addresses (useful for web & auth logs)
    log_header "Top 5 Originating IP Addresses"
    local top_ips
    top_ips=$(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "${TARGET_LOG}" 2>/dev/null \
        | head -n 10000 \
        | sort | uniq -c | sort -rn | head -n 5 || true)

    if [[ -n "${top_ips}" ]]; then
        echo "${top_ips}" | awk '{ printf "  [%d requests] IP: %s\n", $1, $2 }'
    else
        log_info "No IP address patterns identified."
    fi

    # HTTP Status Code Summary (if access log format detected)
    local http_codes
    http_codes=$(grep -oE ' "[A-Z]+ .* HTTP/[0-9.]+" [0-9]{3} ' "${TARGET_LOG}" 2>/dev/null \
        | awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 5 || true)

    if [[ -n "${http_codes}" ]]; then
        log_header "Top HTTP Response Codes"
        echo "${http_codes}" | awk '{ printf "  • HTTP %s : %d responses\n", $2, $1 }'
    fi

    echo ""
}

if [[ "${ANALYZE_MODE}" = true ]]; then
    run_analysis
    exit 0
fi

# ------------------------------------------------------------------------------
# Rotation Execution
# ------------------------------------------------------------------------------
log_header "Log Rotation & Retention Cycle"
CURRENT_SIZE_BYTES=$(wc -c < "${TARGET_LOG}" | awk '{print $1}')
CURRENT_SIZE_MB=$(( CURRENT_SIZE_BYTES / 1024 / 1024 ))
MAX_SIZE_BYTES=$(( MAX_SIZE_MB * 1024 * 1024 ))

log_info "Target Log: '${TARGET_LOG}' (${CURRENT_SIZE_MB}MB / ${MAX_SIZE_MB}MB threshold)"

if (( CURRENT_SIZE_BYTES >= MAX_SIZE_BYTES )); then
    TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
    ROTATED_FILE="${TARGET_LOG}.${TIMESTAMP}"

    if [[ "${DRY_RUN}" = true ]]; then
        log_info "[DRY-RUN] Would perform copytruncate on: '${TARGET_LOG}' -> '${ROTATED_FILE}'"
        if [[ "${COMPRESS_ARCHIVES}" = true ]]; then
            log_info "[DRY-RUN] Would compress rotated archive with gzip: '${ROTATED_FILE}.gz'"
        fi
    else
        log_info "Threshold exceeded. Performing copytruncate rotation..."
        # Copy active log to preserve current writes
        cp -p "${TARGET_LOG}" "${ROTATED_FILE}"
        # Atomically zero active log file while keeping file descriptor open for running daemons
        if command -v truncate >/dev/null 2>&1; then
            truncate -s 0 "${TARGET_LOG}"
        else
            : > "${TARGET_LOG}"
        fi
        log_success "Log rotated to: '$(basename "${ROTATED_FILE}")'"

        # Compress archive
        if [[ "${COMPRESS_ARCHIVES}" = true ]]; then
            log_info "Compressing rotated archive with gzip..."
            gzip -f "${ROTATED_FILE}"
            log_success "Archive compressed: '$(basename "${ROTATED_FILE}.gz")'"
        fi
    fi
else
    log_info "File size is below rotation threshold. Rotation skipped."
fi

# ------------------------------------------------------------------------------
# Retention Pruning
# ------------------------------------------------------------------------------
log_info "Enforcing retention policy (${RETENTION_DAYS} days) in '${LOG_DIR}'..."

PRUNED_COUNT=0
while IFS= read -r old_file; do
    if [[ -n "${old_file}" && -f "${old_file}" ]]; then
        if [[ "${DRY_RUN}" = true ]]; then
            log_info "[DRY-RUN] Would prune expired archive: $(basename "${old_file}")"
        else
            log_info "Pruning expired log archive: $(basename "${old_file}")"
            rm -f "${old_file}"
        fi
        PRUNED_COUNT=$(( PRUNED_COUNT + 1 ))
    fi
done < <(find "${LOG_DIR}" -maxdepth 1 -type f \( -name "${LOG_BASENAME}.*.gz" -o -name "${LOG_BASENAME}.[0-9]*" \) -mtime +"${RETENTION_DAYS}" 2>/dev/null || true)

if [[ "${DRY_RUN}" = true ]]; then
    log_info "[DRY-RUN] Total expired archives eligible for pruning: ${PRUNED_COUNT}"
else
    if (( PRUNED_COUNT > 0 )); then
        log_success "Retention pruning complete: ${PRUNED_COUNT} archive(s) deleted."
    else
        log_info "No rotated archives exceeded the ${RETENTION_DAYS}-day retention window."
    fi
fi

exit 0
