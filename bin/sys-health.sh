#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - System Resource Guardian
# bin/sys-health.sh
#
# Production health monitoring engine. Analyzes CPU, Memory, Load, and Disk
# utilization against threshold limits, emits structured JSON for APM pipelines,
# and fires automated webhook alerts on degradation.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Locate Dependencies
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration resolution
CONFIG_FILE="${PROJECT_ROOT}/config/alerts.conf"
if [[ ! -f "${CONFIG_FILE}" && -f "/etc/linux-admin-scripts/alerts.conf" ]]; then
    CONFIG_FILE="/etc/linux-admin-scripts/alerts.conf"
fi

# ------------------------------------------------------------------------------
# Default Settings
# ------------------------------------------------------------------------------
JSON_MODE=false
QUIET_MODE=false
LOG_OUTPUT_FILE=""
WEBHOOK_OVERRIDE=""

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Monitors host system resources against configured threshold limits.

Options:
  -c <path>     Path to custom alerts.conf file
  -j            Output pure structured JSON to stdout (for APMs / jq)
  -l <file>     Append JSON telemetry entry to specified log file
  -w <url>      Override alert webhook URL
  -q            Quiet mode (suppress console output if status is HEALTHY)
  -v            Verbose / debug output
  -h            Show this help text

Examples:
  $(basename "$0")
  $(basename "$0") -j | jq .
  $(basename "$0") -l /var/log/linux-admin-scripts/sys-health.log
  $(basename "$0") -c /opt/conf/production.conf -q
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while getopts "c:jl:w:qvh" opt; do
    case "${opt}" in
        c) CONFIG_FILE="${OPTARG}" ;;
        j) JSON_MODE=true ;;
        l) LOG_OUTPUT_FILE="${OPTARG}" ;;
        w) WEBHOOK_OVERRIDE="${OPTARG}" ;;
        q) QUIET_MODE=true ;;
        v) LOG_LEVEL="DEBUG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Source configuration
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
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

# Fallback threshold defaults if not configured
CPU_WARN_THRESHOLD="${CPU_WARN_THRESHOLD:-75}"
CPU_CRIT_THRESHOLD="${CPU_CRIT_THRESHOLD:-90}"
MEM_WARN_THRESHOLD="${MEM_WARN_THRESHOLD:-80}"
MEM_CRIT_THRESHOLD="${MEM_CRIT_THRESHOLD:-95}"
DISK_WARN_THRESHOLD="${DISK_WARN_THRESHOLD:-80}"
DISK_CRIT_THRESHOLD="${DISK_CRIT_THRESHOLD:-90}"

# ------------------------------------------------------------------------------
# Telemetry Collection Functions
# ------------------------------------------------------------------------------

# Measure CPU Utilization %
get_cpu_usage() {
    # If /proc/stat is accessible, calculate over a 0.2s delta for precision
    if [[ -r /proc/stat ]]; then
        local prev_total=0 prev_idle=0 idle total delta_total delta_idle
        read -r _ u n s i w irq sirq st _ < /proc/stat
        prev_idle=$(( i + w ))
        prev_total=$(( u + n + s + i + w + irq + sirq + st ))

        sleep 0.2

        read -r _ u n s i w irq sirq st _ < /proc/stat
        idle=$(( i + w ))
        total=$(( u + n + s + i + w + irq + sirq + st ))

        delta_total=$(( total - prev_total ))
        delta_idle=$(( idle - prev_idle ))

        if (( delta_total > 0 )); then
            local usage=$(( (delta_total - delta_idle) * 100 / delta_total ))
            echo "${usage}"
            return 0
        fi
    fi

    # Fallback to load average calculation relative to core count
    local cores
    cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local load
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    # Convert load/cores to approximate percentage
    awk -v l="${load}" -v c="${cores}" 'BEGIN { printf "%d", (l / c) * 100 }'
}

# Measure Memory Usage %
get_memory_usage() {
    if [[ -r /proc/meminfo ]]; then
        local total avail
        total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
        avail=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
        
        # Older kernels without MemAvailable fallback to Free + Buffers + Cached
        if [[ -z "${avail}" ]]; then
            local free b c
            free=$(awk '/MemFree:/ {print $2}' /proc/meminfo)
            b=$(awk '/Buffers:/ {print $2}' /proc/meminfo)
            c=$(awk '/^Cached:/ {print $2}' /proc/meminfo)
            avail=$(( free + b + c ))
        fi

        if (( total > 0 )); then
            echo "$(( (total - avail) * 100 / total ))"
            return 0
        fi
    fi

    # Fallback using `free -m`
    free -m | awk 'NR==2 { printf "%d", ($3 / $2) * 100 }'
}

# Measure Root Disk Partition %
get_disk_usage() {
    df -P / | awk 'NR==2 { gsub("%", "", $5); print $5 }'
}

# ------------------------------------------------------------------------------
# Main Health Assessment
# ------------------------------------------------------------------------------
HOSTNAME_STR="$(hostname 2>/dev/null || echo "localhost")"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")"
CPU_PCT=$(get_cpu_usage)
MEM_PCT=$(get_memory_usage)
DISK_PCT=$(get_disk_usage)
LOAD_1M=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.00")
CORES=$(nproc 2>/dev/null || echo 1)

STATUS="HEALTHY"
BREACH_REASONS=()

# Evaluate CPU
if (( CPU_PCT >= CPU_CRIT_THRESHOLD )); then
    STATUS="CRITICAL"
    BREACH_REASONS+=("CPU utilization CRITICAL: ${CPU_PCT}% (threshold: ${CPU_CRIT_THRESHOLD}%)")
elif (( CPU_PCT >= CPU_WARN_THRESHOLD )); then
    [[ "${STATUS}" != "CRITICAL" ]] && STATUS="WARNING"
    BREACH_REASONS+=("CPU utilization HIGH: ${CPU_PCT}% (threshold: ${CPU_WARN_THRESHOLD}%)")
fi

# Evaluate Memory
if (( MEM_PCT >= MEM_CRIT_THRESHOLD )); then
    STATUS="CRITICAL"
    BREACH_REASONS+=("Memory usage CRITICAL: ${MEM_PCT}% (threshold: ${MEM_CRIT_THRESHOLD}%)")
elif (( MEM_PCT >= MEM_WARN_THRESHOLD )); then
    [[ "${STATUS}" != "CRITICAL" ]] && STATUS="WARNING"
    BREACH_REASONS+=("Memory usage HIGH: ${MEM_PCT}% (threshold: ${MEM_WARN_THRESHOLD}%)")
fi

# Evaluate Disk
if (( DISK_PCT >= DISK_CRIT_THRESHOLD )); then
    STATUS="CRITICAL"
    BREACH_REASONS+=("Root disk partition CRITICAL: ${DISK_PCT}% (threshold: ${DISK_CRIT_THRESHOLD}%)")
elif (( DISK_PCT >= DISK_WARN_THRESHOLD )); then
    [[ "${STATUS}" != "CRITICAL" ]] && STATUS="WARNING"
    BREACH_REASONS+=("Root disk partition HIGH: ${DISK_PCT}% (threshold: ${DISK_WARN_THRESHOLD}%)")
fi

# Build JSON array of breach alerts
JSON_BREACHES="[]"
if (( ${#BREACH_REASONS[@]} > 0 )); then
    JSON_BREACHES=$(printf '%s\n' "${BREACH_REASONS[@]}" | awk 'BEGIN { printf "[" } { if (NR>1) printf ", "; printf "\"%s\"", $0 } END { printf "]" }')
fi

# Assemble Structured JSON Telemetry Payload
JSON_PAYLOAD=$(cat <<EOF
{"timestamp":"${TIMESTAMP}","hostname":"${HOSTNAME_STR}","cpu_pct":${CPU_PCT},"mem_pct":${MEM_PCT},"disk_pct":${DISK_PCT},"load_1m":"${LOAD_1M}","cpu_cores":${CORES},"status":"${STATUS}","breaches":${JSON_BREACHES}}
EOF
)

# Append to log file if requested
if [[ -n "${LOG_OUTPUT_FILE}" ]]; then
    LOG_OUTPUT_DIR="$(dirname "${LOG_OUTPUT_FILE}")"
    if [[ ! -d "${LOG_OUTPUT_DIR}" ]]; then
        mkdir -p "${LOG_OUTPUT_DIR}"
    fi
    echo "${JSON_PAYLOAD}" >> "${LOG_OUTPUT_FILE}"
fi

# Dispatch alert notifications if degraded
if [[ "${STATUS}" != "HEALTHY" ]]; then
    ALERT_MSG="Health Status: [${STATUS}] on ${HOSTNAME_STR} | CPU: ${CPU_PCT}% | MEM: ${MEM_PCT}% | DISK: ${DISK_PCT}%. Details: "
    for reason in "${BREACH_REASONS[@]}"; do
        ALERT_MSG="${ALERT_MSG}[${reason}] "
    done
    send_notification "System Health Alert: ${STATUS}" "${ALERT_MSG}" "${STATUS}" "${WEBHOOK_OVERRIDE}" || true
fi

# ------------------------------------------------------------------------------
# Output Presentation
# ------------------------------------------------------------------------------
if [[ "${JSON_MODE}" = true ]]; then
    echo "${JSON_PAYLOAD}"
    exit 0
fi

if [[ "${QUIET_MODE}" = true && "${STATUS}" == "HEALTHY" ]]; then
    exit 0
fi

log_header "Host System Resource Telemetry"
log_info "Host: ${HOSTNAME_STR} | Cores: ${CORES} | 1-min Load: ${LOAD_1M}"
log_info "CPU Usage:       ${CPU_PCT}% (Warn: ${CPU_WARN_THRESHOLD}%, Crit: ${CPU_CRIT_THRESHOLD}%)"
log_info "Memory Usage:    ${MEM_PCT}% (Warn: ${MEM_WARN_THRESHOLD}%, Crit: ${MEM_CRIT_THRESHOLD}%)"
log_info "Disk Usage (/):  ${DISK_PCT}% (Warn: ${DISK_WARN_THRESHOLD}%, Crit: ${DISK_CRIT_THRESHOLD}%)"

if [[ "${STATUS}" == "HEALTHY" ]]; then
    log_success "System Health: [${STATUS}] - All parameters operating within normal parameters."
elif [[ "${STATUS}" == "WARNING" ]]; then
    log_warn "System Health: [${STATUS}] - Resource limits warning triggered."
    for reason in "${BREACH_REASONS[@]}"; do
        log_warn "  -> ${reason}"
    done
else
    log_error "System Health: [${STATUS}] - Immediate operational action required!"
    for reason in "${BREACH_REASONS[@]}"; do
        log_error "  -> ${reason}"
    done
fi

# Exit with non-zero code on CRITICAL for orchestration hooks
if [[ "${STATUS}" == "CRITICAL" ]]; then
    exit 2
elif [[ "${STATUS}" == "WARNING" ]]; then
    exit 1
fi

exit 0
