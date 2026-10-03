#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Reusable Notification Library
# lib/notify.sh
#
# Supports Slack, Discord, and generic JSON webhooks with automatic formatting,
# timeout safeguards, and fallback logging when webhooks are not configured.
# ==============================================================================

# Prevent duplicate sourcing
if [[ -n "${_NOTIFY_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_NOTIFY_SH_LOADED=1

# Source logger if available
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_LIB_DIR}/logger.sh" ]]; then
    # shellcheck source=lib/logger.sh
    source "${_LIB_DIR}/logger.sh"
fi

# ------------------------------------------------------------------------------
# send_notification
# Arguments:
#   $1 - Title (e.g., "Backup Completed", "High Memory Warning")
#   $2 - Message body
#   $3 - Severity: INFO, SUCCESS, WARN, CRITICAL (default: INFO)
#   $4 - Webhook URL (optional; falls back to $WEBHOOK_URL env var)
# Returns:
#   0 on success or skipped, 1 on curl network error
# ------------------------------------------------------------------------------
send_notification() {
    local title="${1:-System Notification}"
    local message="${2:-No details provided}"
    local severity="${3:-INFO}"
    local webhook="${4:-${WEBHOOK_URL:-}}"
    local hostname
    hostname="$(hostname 2>/dev/null || echo "unknown-host")"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")"

    # If no webhook URL is defined, log locally and exit gracefully
    if [[ -z "${webhook}" ]]; then
        log_info "Notification: [${severity^^}] [${title}] ${message}"
        return 0
    fi

    # Ensure curl exists
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl is not installed; unable to dispatch webhook notification."
        return 0
    fi

    local payload=""

    # 1. Discord Webhook Format
    if [[ "${webhook}" =~ discord(app)?\.com/api/webhooks ]]; then
        local color_code=3447003 # Blue for INFO
        case "${severity^^}" in
            SUCCESS)  color_code=3066993 ;; # Green
            WARN)     color_code=16776960 ;; # Yellow
            CRITICAL) color_code=15158332 ;; # Red
        esac

        payload=$(cat <<EOF
{
  "username": "Linux Admin Bot (${hostname})",
  "embeds": [
    {
      "title": "[${severity^^}] ${title}",
      "description": "${message}",
      "color": ${color_code},
      "footer": { "text": "Host: ${hostname}" },
      "timestamp": "${timestamp}"
    }
  ]
}
EOF
)

    # 2. Slack Webhook Format
    elif [[ "${webhook}" =~ hooks\.slack\.com/services ]]; then
        local emoji=":information_source:"
        case "${severity^^}" in
            SUCCESS)  emoji=":white_check_mark:" ;;
            WARN)     emoji=":warning:" ;;
            CRITICAL) emoji=":rotating_light:" ;;
        esac

        payload=$(cat <<EOF
{
  "text": "${emoji} *[${severity^^}] ${title}* on \`${hostname}\`\n>${message}"
}
EOF
)

    # 3. Generic JSON Webhook (Datadog, Custom API, etc.)
    else
        payload=$(cat <<EOF
{
  "title": "${title}",
  "message": "${message}",
  "severity": "${severity^^}",
  "hostname": "${hostname}",
  "timestamp": "${timestamp}"
}
EOF
)
    fi

    # Send POST request with 10s connection timeout and 15s max time
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 15 \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${webhook}" 2>/dev/null || echo "000")

    if [[ "${http_code}" =~ ^2 ]]; then
        log_debug "Webhook delivered successfully (HTTP ${http_code})."
        return 0
    else
        log_warn "Webhook dispatch returned HTTP status ${http_code}."
        return 1
    fi
}
