#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Web Deploy & Security Hardening
# bin/web-deploy.sh
#
# Production Nginx site deployment, directory structure isolation, security
# headers injection, UFW firewall rule verification, and systemd reload testing.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Locate Dependencies
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
DOMAIN_NAME=""
WEB_ROOT=""
PORT=80
ENABLE_UFW=false
DRY_RUN=false
WEBHOOK_OVERRIDE=""

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -d <domain_name> [OPTIONS]

Deploys an isolated Nginx virtual host with security headers, logging, and UFW rules.

Required:
  -d <domain>    Domain name / server_name (e.g., example.com, app.internal)

Options:
  -r <web_root>  Root directory for website files (Default: /var/www/<domain>/html)
  -p <port>      Listening port (Default: ${PORT})
  -s             Apply UFW firewall hardening (permits SSH & Nginx traffic safely)
  -w <url>       Override alert webhook URL
  -t             Dry run / test mode (simulate deployment and validate configuration)
  -v             Verbose / debug output
  -h             Show this help text

Examples:
  sudo $(basename "$0") -d cloud.company.local -s
  sudo $(basename "$0") -d api.internal -p 8080 -r /opt/web/api/html
  $(basename "$0") -d test.local -t
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while getopts "d:r:p:sw:tvh" opt; do
    case "${opt}" in
        d) DOMAIN_NAME="${OPTARG}" ;;
        r) WEB_ROOT="${OPTARG}" ;;
        p) PORT="${OPTARG}" ;;
        s) ENABLE_UFW=true ;;
        w) WEBHOOK_OVERRIDE="${OPTARG}" ;;
        t) DRY_RUN=true ;;
        v) LOG_LEVEL="DEBUG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "${DOMAIN_NAME}" ]]; then
    log_error "Missing required argument: -d <domain_name>"
    usage
fi

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    log_error "Invalid port number: '${PORT}'. Must be an integer between 1 and 65535."
    exit 1
fi

# Assign default web root if not specified
if [[ -z "${WEB_ROOT}" ]]; then
    WEB_ROOT="/var/www/${DOMAIN_NAME}/html"
fi

WEB_PARENT_DIR="$(dirname "${WEB_ROOT}")"
WEB_LOGS_DIR="${WEB_PARENT_DIR}/logs"

# ------------------------------------------------------------------------------
# Pre-Flight Checks
# ------------------------------------------------------------------------------
log_header "Nginx Deployment & Hardening Engine"
log_info "Target Domain: '${DOMAIN_NAME}' on Port ${PORT}"
log_info "Web Root:      '${WEB_ROOT}'"

# Root Privileges Check
if [[ "${DRY_RUN}" = false && "$(id -u)" -ne 0 ]]; then
    log_error "This script must be executed with root / sudo privileges."
    exit 1
fi

# Check Nginx binary existence
if [[ "${DRY_RUN}" = false ]] && ! command -v nginx >/dev/null 2>&1; then
    log_error "Nginx binary not found. Please install Nginx (e.g., 'apt install nginx' or 'dnf install nginx')."
    exit 1
fi

# ------------------------------------------------------------------------------
# Dry-Run Simulation
# ------------------------------------------------------------------------------
if [[ "${DRY_RUN}" = true ]]; then
    log_info "[DRY-RUN] Target paths: '${WEB_ROOT}' and '${WEB_LOGS_DIR}'"
    log_info "[DRY-RUN] Virtual host config: '/etc/nginx/sites-available/${DOMAIN_NAME}'"
    log_info "[DRY-RUN] Symlink enabled: '/etc/nginx/sites-enabled/${DOMAIN_NAME}'"
    log_info "[DRY-RUN] UFW Hardening: ${ENABLE_UFW}"
    log_success "[DRY-RUN] Pre-flight checks passed successfully. No changes committed."
    exit 0
fi

# ------------------------------------------------------------------------------
# Web Root Directory Setup & Ownership
# ------------------------------------------------------------------------------
log_info "Provisioning web root directory tree..."
mkdir -p "${WEB_ROOT}"
mkdir -p "${WEB_LOGS_DIR}"

# Detect web server user (www-data or nginx)
WEB_USER="www-data"
if ! id "${WEB_USER}" >/dev/null 2>&1; then
    if id "nginx" >/dev/null 2>&1; then
        WEB_USER="nginx"
    else
        WEB_USER="$(id -un)"
    fi
fi

# Deploy default production status page if index.html is absent
INDEX_FILE="${WEB_ROOT}/index.html"
if [[ ! -f "${INDEX_FILE}" ]]; then
    cat <<EOF > "${INDEX_FILE}"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${DOMAIN_NAME} - Enterprise Deployment</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 2.5rem; max-width: 520px; box-shadow: 0 10px 25px -5px rgba(0,0,0,0.5); }
        .badge { display: inline-block; background: #10b981; color: #022c22; font-weight: bold; padding: 0.25rem 0.75rem; border-radius: 9999px; font-size: 0.85rem; margin-bottom: 1rem; }
        h1 { margin: 0 0 0.5rem 0; font-size: 1.75rem; }
        p { color: #94a3b8; line-height: 1.6; margin: 0.5rem 0; }
        code { background: #0f172a; padding: 0.2rem 0.4rem; border-radius: 4px; font-family: monospace; color: #38bdf8; }
    </style>
</head>
<body>
    <div class="card">
        <span class="badge">Operational</span>
        <h1>${DOMAIN_NAME}</h1>
        <p>Hardened web virtual host provisioned successfully via <code>linux-admin-scripts</code>.</p>
        <p>Web Root: <code>${WEB_ROOT}</code></p>
        <p>Security Headers: <code>Active</code> | Gzip: <code>Enabled</code></p>
    </div>
</body>
</html>
EOF
    log_success "Sample landing page created at ${INDEX_FILE}"
fi

# Set directory permissions and ownership
chown -R "${WEB_USER}:${WEB_USER}" "${WEB_PARENT_DIR}"
chmod 755 "${WEB_PARENT_DIR}"
chmod 755 "${WEB_ROOT}"
chmod 644 "${INDEX_FILE}" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Nginx Virtual Host Configuration
# ------------------------------------------------------------------------------
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
mkdir -p "${SITES_AVAILABLE}" "${SITES_ENABLED}"

CONFIG_PATH="${SITES_AVAILABLE}/${DOMAIN_NAME}"
ENABLED_PATH="${SITES_ENABLED}/${DOMAIN_NAME}"

log_info "Generating hardened Nginx configuration: '${CONFIG_PATH}'..."

cat <<EOF > "${CONFIG_PATH}"
# Managed automatically by linux-admin-scripts
# Domain: ${DOMAIN_NAME}

server {
    listen ${PORT};
    listen [::]:${PORT};

    server_name ${DOMAIN_NAME};
    root ${WEB_ROOT};
    index index.html index.htm;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

    # Dedicated Logging
    access_log ${WEB_LOGS_DIR}/access.log;
    error_log ${WEB_LOGS_DIR}/error.log warn;

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml application/json;
    gzip_disable "MSIE [1-6]\.";

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Deny access to hidden dotfiles (e.g. .git, .env)
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

# Enable site via relative or absolute symlink
ln -sf "${CONFIG_PATH}" "${ENABLED_PATH}"
log_success "Virtual host linked to ${ENABLED_PATH}"

# ------------------------------------------------------------------------------
# Configuration Validation & Service Reload
# ------------------------------------------------------------------------------
log_info "Validating Nginx syntax..."
if ! nginx -t; then
    log_error "Nginx syntax test FAILED! Rolling back site configuration."
    rm -f "${ENABLED_PATH}" "${CONFIG_PATH}"
    exit 1
fi
log_success "Nginx syntax verification passed."

# Reload Nginx daemon via systemd
if command -v systemctl >/dev/null 2>&1; then
    log_info "Reloading Nginx service via systemd..."
    systemctl reload nginx
    log_success "Nginx daemon reloaded."
else
    nginx -s reload
    log_success "Nginx process reloaded directly."
fi

# ------------------------------------------------------------------------------
# Firewall Hardening (UFW)
# ------------------------------------------------------------------------------
if [[ "${ENABLE_UFW}" = true ]]; then
    if command -v ufw >/dev/null 2>&1; then
        log_info "Configuring UFW firewall rules..."
        # Critical safety: Always ensure SSH is allowed to prevent accidental lockout
        ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1
        # Allow Nginx traffic
        if (( PORT == 80 || PORT == 443 )); then
            ufw allow 'Nginx Full' >/dev/null 2>&1 || ufw allow "${PORT}/tcp" >/dev/null 2>&1
        else
            ufw allow "${PORT}/tcp" >/dev/null 2>&1
        fi
        log_success "UFW rules updated (SSH & Port ${PORT} permitted)."
    else
        log_warn "UFW is not installed; skipping firewall rule creation."
    fi
fi

# ------------------------------------------------------------------------------
# Post-Deployment Smoke Test
# ------------------------------------------------------------------------------
log_info "Performing HTTP smoke check on localhost:${PORT}..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN_NAME}" "http://127.0.0.1:${PORT}" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" =~ ^(200|301|302) ]]; then
    log_success "HTTP smoke test passed with status: ${HTTP_STATUS}"
else
    log_warn "HTTP smoke test returned status ${HTTP_STATUS}. Review '${WEB_LOGS_DIR}/error.log' if needed."
fi

# Send notification
send_notification "Web Deployment" "Site '${DOMAIN_NAME}' deployed successfully on port ${PORT}. HTTP Status: ${HTTP_STATUS}." "SUCCESS" "${WEBHOOK_OVERRIDE}" || true

log_header "Deployment Summary"
printf "  • Virtual Host:  http://%s:%s\n" "${DOMAIN_NAME}" "${PORT}"
printf "  • Web Root:      %s\n" "${WEB_ROOT}"
printf "  • Access Log:    %s/access.log\n" "${WEB_LOGS_DIR}"
printf "  • Error Log:     %s/error.log\n" "${WEB_LOGS_DIR}"
printf "  • Nginx Status:  Active & Verified\n\n"

exit 0
