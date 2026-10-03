#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Enterprise Backup Engine
# bin/backup-engine.sh
#
# Production-grade backup solution featuring strict error handling, disk space
# pre-flight validation, SHA-256 integrity verification, automated retention
# pruning, and webhook notifications.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Locate Dependencies (Repo root or standard system installation)
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
SOURCE_DIR=""
DEST_DIR="${DEFAULT_BACKUP_DEST:-/var/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
WEBHOOK_OVERRIDE=""
DRY_RUN=false
TMP_WORK_DIR=""

# ------------------------------------------------------------------------------
# Trap & Cleanup
# ------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ -n "${TMP_WORK_DIR:-}" && -d "${TMP_WORK_DIR}" ]]; then
        rm -rf "${TMP_WORK_DIR}"
        log_debug "Temporary workspace removed: ${TMP_WORK_DIR}"
    fi

    if (( exit_code != 0 )); then
        log_error "Backup process aborted with exit code ${exit_code}."
        if [[ -n "${SOURCE_DIR:-}" ]]; then
            send_notification "Backup Failure" "Backup of '${SOURCE_DIR}' terminated unexpectedly (code: ${exit_code})." "CRITICAL" "${WEBHOOK_OVERRIDE}" || true
        fi
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -s <source_path> [OPTIONS]

Enterprise automated backup with compression, checksums, and retention pruning.

Required:
  -s <path>     Path to the source directory or file to back up

Options:
  -d <path>     Destination backup directory (Default: ${DEST_DIR})
  -r <days>     Retention period in days before pruning old archives (Default: ${RETENTION_DAYS})
  -w <url>      Override alert webhook URL (Slack / Discord / Custom JSON)
  -n            Dry run mode (validate paths and calculate sizes without writing)
  -v            Verbose / debug output
  -h            Show this help text

Examples:
  $(basename "$0") -s /etc/nginx -d /var/backups/nginx
  $(basename "$0") -s /var/www/app -d /mnt/backups -r 14 -w "https://discord.com/api/webhooks/..."
  $(basename "$0") -s /home/developer -n
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while getopts "s:d:r:w:nvh" opt; do
    case "${opt}" in
        s) SOURCE_DIR="${OPTARG}" ;;
        d) DEST_DIR="${OPTARG}" ;;
        r) RETENTION_DAYS="${OPTARG}" ;;
        w) WEBHOOK_OVERRIDE="${OPTARG}" ;;
        n) DRY_RUN=true ;;
        v) LOG_LEVEL="DEBUG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "${SOURCE_DIR}" ]]; then
    log_error "Missing required argument: -s <source_path>"
    usage
fi

if ! [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
    log_error "Retention days (-r) must be a positive integer. Got: '${RETENTION_DAYS}'"
    exit 1
fi

# ------------------------------------------------------------------------------
# Pre-Flight Checks
# ------------------------------------------------------------------------------
log_header "Backup Engine Execution"
log_info "Initializing backup for source: '${SOURCE_DIR}'"

# 1. Validate Source Path
if [[ ! -e "${SOURCE_DIR}" ]]; then
    log_error "Source path does not exist: '${SOURCE_DIR}'"
    exit 1
fi

if [[ ! -r "${SOURCE_DIR}" ]]; then
    log_error "Source path is not readable (check permissions): '${SOURCE_DIR}'"
    exit 1
fi

# Canonicalize source path
SOURCE_DIR="$(cd "$(dirname "${SOURCE_DIR}")" && pwd)/$(basename "${SOURCE_DIR}")"
SOURCE_BASENAME="$(basename "${SOURCE_DIR}")"
SOURCE_PARENT="$(dirname "${SOURCE_DIR}")"

# 2. Prepare Destination Directory
if [[ "${DRY_RUN}" = false ]]; then
    if [[ ! -d "${DEST_DIR}" ]]; then
        log_info "Creating destination directory: '${DEST_DIR}'"
        mkdir -p "${DEST_DIR}"
    fi

    if [[ ! -w "${DEST_DIR}" ]]; then
        log_error "Destination directory is not writable: '${DEST_DIR}'"
        exit 1
    fi
else
    log_info "[DRY-RUN] Destination check: '${DEST_DIR}'"
fi

# 3. Disk Space Verification
# Calculate source size in Kilobytes
SOURCE_SIZE_KB=$(du -sk "${SOURCE_DIR}" | awk '{print $1}')
SOURCE_HUMAN=$(du -sh "${SOURCE_DIR}" | awk '{print $1}')

# Check available space on destination filesystem in Kilobytes
if [[ -d "${DEST_DIR}" ]]; then
    DEST_CHECK_PATH="${DEST_DIR}"
else
    DEST_CHECK_PATH="$(dirname "${DEST_DIR}")"
fi

# POSIX-compliant df parsing
AVAIL_SPACE_KB=$(df -k -P "${DEST_CHECK_PATH}" | awk 'NR==2 {print $4}')

# Add 15% safety buffer for temporary storage and tar overhead
REQUIRED_SPACE_KB=$(( SOURCE_SIZE_KB + (SOURCE_SIZE_KB * 15 / 100) ))

log_info "Source size: ${SOURCE_HUMAN} (${SOURCE_SIZE_KB} KB)"
log_info "Available disk space at destination: $(( AVAIL_SPACE_KB / 1024 )) MB"

if (( AVAIL_SPACE_KB < REQUIRED_SPACE_KB )); then
    log_error "Insufficient disk space! Required: $(( REQUIRED_SPACE_KB / 1024 )) MB, Available: $(( AVAIL_SPACE_KB / 1024 )) MB"
    exit 2
fi

# Create secure temporary directory for staging
TMP_WORK_DIR=$(mktemp -d -t backup-engine-XXXXXX)
log_debug "Staging directory created: ${TMP_WORK_DIR}"

# ------------------------------------------------------------------------------
# Archive Creation & Integrity Check
# ------------------------------------------------------------------------------
TIMESTAMP="$(date +'%Y-%m-%d_%H%M%S')"
ARCHIVE_FILENAME="backup-${SOURCE_BASENAME}-${TIMESTAMP}.tar.gz"
ARCHIVE_FILEPATH="${DEST_DIR}/${ARCHIVE_FILENAME}"
CHECKSUM_FILEPATH="${ARCHIVE_FILEPATH}.sha256"

if [[ "${DRY_RUN}" = true ]]; then
    log_info "[DRY-RUN] Would create archive: '${ARCHIVE_FILEPATH}'"
    log_info "[DRY-RUN] Would generate SHA-256 checksum: '${CHECKSUM_FILEPATH}'"
    log_info "[DRY-RUN] Would prune archives older than ${RETENTION_DAYS} days in '${DEST_DIR}'"
    log_success "[DRY-RUN] Pre-flight checks passed successfully. No files created."
    exit 0
fi

log_info "Creating compressed archive: '${ARCHIVE_FILENAME}'..."
tar -czf "${ARCHIVE_FILEPATH}" -C "${SOURCE_PARENT}" "${SOURCE_BASENAME}"

# Confirm file exists and has size
if [[ ! -s "${ARCHIVE_FILEPATH}" ]]; then
    log_error "Archive creation failed or generated an empty file."
    exit 1
fi
ARCHIVE_SIZE=$(du -sh "${ARCHIVE_FILEPATH}" | awk '{print $1}')
log_success "Archive generated successfully (${ARCHIVE_SIZE})."

# Generate and verify SHA-256 Checksum
log_info "Generating SHA-256 checksum..."
(cd "${DEST_DIR}" && sha256sum "${ARCHIVE_FILENAME}" > "${ARCHIVE_FILENAME}.sha256")

log_info "Verifying archive integrity against checksum..."
(cd "${DEST_DIR}" && sha256sum -c "${ARCHIVE_FILENAME}.sha256" --status)
log_success "Integrity check PASSED: Checksum verified."

# ------------------------------------------------------------------------------
# Retention Pruning
# ------------------------------------------------------------------------------
log_info "Checking for expired archives (retention threshold: ${RETENTION_DAYS} days)..."

# Find older archives with matching prefix
PRUNED_COUNT=0
while IFS= read -r old_archive; do
    if [[ -n "${old_archive}" && -f "${old_archive}" ]]; then
        log_info "Pruning expired archive: $(basename "${old_archive}")"
        rm -f "${old_archive}"
        rm -f "${old_archive}.sha256"
        PRUNED_COUNT=$(( PRUNED_COUNT + 1 ))
    fi
done < <(find "${DEST_DIR}" -maxdepth 1 -type f -name "backup-${SOURCE_BASENAME}-*.tar.gz" -mtime +"${RETENTION_DAYS}" 2>/dev/null || true)

if (( PRUNED_COUNT > 0 )); then
    log_success "Pruned ${PRUNED_COUNT} expired archive(s)."
else
    log_info "No archives exceeded the retention window."
fi

# ------------------------------------------------------------------------------
# Notification & Completion
# ------------------------------------------------------------------------------
SUMMARY_MSG="Archive '${ARCHIVE_FILENAME}' (${ARCHIVE_SIZE}) created. Integrity verified. Old archives pruned: ${PRUNED_COUNT}."
log_success "Backup finished successfully."
log_info "${SUMMARY_MSG}"

send_notification "Backup Completed" "${SUMMARY_MSG}" "SUCCESS" "${WEBHOOK_OVERRIDE}" || true

exit 0
