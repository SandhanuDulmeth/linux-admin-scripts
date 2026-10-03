#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Reusable Logging Library
# lib/logger.sh
#
# Provides structured, color-coded logging with automatic TTY detection,
# ISO-8601 timestamps, log levels, and standard error separation.
# ==============================================================================

# Prevent duplicate sourcing
if [[ -n "${_LOGGER_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_LOGGER_SH_LOADED=1

# ------------------------------------------------------------------------------
# Color Definitions (automatically disabled if stdout/stderr is not a TTY)
# ------------------------------------------------------------------------------
if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_MAGENTA='\033[0;35m'
    COLOR_CYAN='\033[0;36m'
    COLOR_BOLD='\033[1m'
    COLOR_RESET='\033[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_MAGENTA=''
    COLOR_CYAN=''
    COLOR_BOLD=''
    COLOR_RESET=''
fi

# ------------------------------------------------------------------------------
# Log Level Hierarchy: DEBUG (0) < INFO (1) < WARN (2) < ERROR (3)
# Default level: INFO
# Override by setting LOG_LEVEL in environment (e.g. LOG_LEVEL=DEBUG)
# ------------------------------------------------------------------------------
LOG_LEVEL="${LOG_LEVEL:-INFO}"

_log_level_to_int() {
    case "${1^^}" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

_current_log_level_int() {
    _log_level_to_int "$LOG_LEVEL"
}

_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# ------------------------------------------------------------------------------
# Public Logging Functions
# ------------------------------------------------------------------------------

# General informational messages
log_info() {
    local threshold current
    threshold=$(_log_level_to_int "INFO")
    current=$(_current_log_level_int)
    if (( current <= threshold )); then
        printf "[%s] [${COLOR_GREEN}INFO${COLOR_RESET}]  %b\n" "$(_timestamp)" "$*"
    fi
}

# Successful milestones or operational confirmations
log_success() {
    local threshold current
    threshold=$(_log_level_to_int "INFO")
    current=$(_current_log_level_int)
    if (( current <= threshold )); then
        printf "[%s] [${COLOR_CYAN}OK${COLOR_RESET}]    %b\n" "$(_timestamp)" "$*"
    fi
}

# Non-fatal warnings and threshold anomalies
log_warn() {
    local threshold current
    threshold=$(_log_level_to_int "WARN")
    current=$(_current_log_level_int)
    if (( current <= threshold )); then
        printf "[%s] [${COLOR_YELLOW}WARN${COLOR_RESET}]  %b\n" "$(_timestamp)" "$*"
    fi
}

# Critical errors and fatal failures (always redirected to stderr)
log_error() {
    local threshold current
    threshold=$(_log_level_to_int "ERROR")
    current=$(_current_log_level_int)
    if (( current <= threshold )); then
        printf "[%s] [${COLOR_RED}ERROR${COLOR_RESET}] %b\n" "$(_timestamp)" "$*" >&2
    fi
}

# Debug messages for deep troubleshooting (enabled via LOG_LEVEL=DEBUG or -v)
log_debug() {
    local threshold current
    threshold=$(_log_level_to_int "DEBUG")
    current=$(_current_log_level_int)
    if (( current <= threshold )); then
        printf "[%s] [${COLOR_BLUE}DEBUG${COLOR_RESET}] %b\n" "$(_timestamp)" "$*"
    fi
}

# Section / Banner header for multi-step jobs
log_header() {
    printf "\n${COLOR_BOLD}${COLOR_MAGENTA}=== %s ===${COLOR_RESET}\n" "$*"
}
