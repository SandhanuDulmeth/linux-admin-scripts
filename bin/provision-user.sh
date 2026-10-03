#!/usr/bin/env bash
# ==============================================================================
# Linux Admin Scripts - Hardened User & SSH Provisioner
# bin/provision-user.sh
#
# Production user provisioning engine featuring secure random credentials,
# SSH key hardening, forced initial password expiry, and verified sudoers rules.
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
TARGET_USER=""
SSH_KEY_INPUT=""
GRANT_SUDO=false
PASSWORDLESS_SUDO=false
USER_SHELL="/bin/bash"
FORCE_PASSWORD_CHANGE=true
DRY_RUN=false
WEBHOOK_OVERRIDE=""

# ------------------------------------------------------------------------------
# Help & Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -u <username> [OPTIONS]

Provisions a hardened Linux user account with SSH key setup and access policies.

Required:
  -u <username>   Username for the new account (alphanumeric, max 32 chars)

Options:
  -k <key_or_file> Public SSH key string or path to an existing .pub file
  -s              Grant standard sudo group membership
  -p              Configure passwordless sudo (NOPASSWD via sudoers.d)
  -b <shell>      Login shell path (Default: ${USER_SHELL})
  -w <url>        Override alert webhook URL
  -n              Dry run mode (simulate provisioning steps without creating user)
  -v              Verbose / debug output
  -h              Show this help text

Examples:
  sudo $(basename "$0") -u deployer -k "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..." -s
  sudo $(basename "$0") -u ci-runner -k ~/.ssh/id_rsa.pub -p
  $(basename "$0") -u testuser -n
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while getopts "u:k:spb:w:nvh" opt; do
    case "${opt}" in
        u) TARGET_USER="${OPTARG}" ;;
        k) SSH_KEY_INPUT="${OPTARG}" ;;
        s) GRANT_SUDO=true ;;
        p) PASSWORDLESS_SUDO=true; GRANT_SUDO=true ;;
        b) USER_SHELL="${OPTARG}" ;;
        w) WEBHOOK_OVERRIDE="${OPTARG}" ;;
        n) DRY_RUN=true ;;
        v) LOG_LEVEL="DEBUG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "${TARGET_USER}" ]]; then
    log_error "Missing required argument: -u <username>"
    usage
fi

# ------------------------------------------------------------------------------
# Pre-Flight Checks & Validations
# ------------------------------------------------------------------------------
log_header "User Provisioning Engine"

# 1. Root Privileges Check
if [[ "${DRY_RUN}" = false && "$(id -u)" -ne 0 ]]; then
    log_error "This script must be executed with root / sudo privileges."
    exit 1
fi

# 2. Username Syntax Validation (POSIX standard)
if ! [[ "${TARGET_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    log_error "Invalid username format: '${TARGET_USER}'. Must begin with lowercase letter/underscore and be <= 32 chars."
    exit 1
fi

# 3. Check for Existing Account
if id "${TARGET_USER}" >/dev/null 2>&1; then
    log_error "User '${TARGET_USER}' already exists on this system."
    exit 1
fi

# 4. Validate Shell Existence
if [[ "${DRY_RUN}" = false && ! -x "${USER_SHELL}" ]]; then
    log_error "Specified shell '${USER_SHELL}' does not exist or is not executable."
    exit 1
fi

# 5. Process SSH Public Key if supplied
SSH_PUBLIC_KEY=""
if [[ -n "${SSH_KEY_INPUT}" ]]; then
    if [[ -f "${SSH_KEY_INPUT}" ]]; then
        SSH_PUBLIC_KEY="$(<"${SSH_KEY_INPUT}")"
    else
        SSH_PUBLIC_KEY="${SSH_KEY_INPUT}"
    fi

    # Basic SSH key format sanity check
    if ! [[ "${SSH_PUBLIC_KEY}" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) ]]; then
        log_error "Invalid SSH public key format provided in -k option."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Generate Hardened Password
# ------------------------------------------------------------------------------
# Generate high-entropy 24-character password
if command -v openssl >/dev/null 2>&1; then
    GENERATED_PASSWORD="$(openssl rand -base64 18 | tr '+/' '-_')"
else
    GENERATED_PASSWORD="$(tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 24 || true)"
fi

if [[ -z "${GENERATED_PASSWORD}" ]]; then
    log_error "Failed to generate random password entropy."
    exit 1
fi

# ------------------------------------------------------------------------------
# Provisioning Execution
# ------------------------------------------------------------------------------
if [[ "${DRY_RUN}" = true ]]; then
    log_info "[DRY-RUN] Would create user: '${TARGET_USER}' with shell '${USER_SHELL}'"
    log_info "[DRY-RUN] Would configure home directory: '/home/${TARGET_USER}'"
    log_info "[DRY-RUN] Sudo membership: ${GRANT_SUDO} (Passwordless: ${PASSWORDLESS_SUDO})"
    if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
        log_info "[DRY-RUN] Would install authorized SSH key into '/home/${TARGET_USER}/.ssh/authorized_keys'"
    fi
    log_success "[DRY-RUN] User provisioning validation complete. No changes made."
    exit 0
fi

log_info "Creating user account '${TARGET_USER}'..."
useradd -m -s "${USER_SHELL}" "${TARGET_USER}"
log_success "Account created with home directory: /home/${TARGET_USER}"

# Set user password securely via pipe
log_info "Configuring account credentials..."
echo "${TARGET_USER}:${GENERATED_PASSWORD}" | chpasswd

# Force password change upon initial interactive login
if [[ "${FORCE_PASSWORD_CHANGE}" = true ]]; then
    chage -d 0 "${TARGET_USER}"
    log_info "Account flagged: password change required on initial login."
fi

# ------------------------------------------------------------------------------
# SSH Public Key Configuration & Hardening
# ------------------------------------------------------------------------------
USER_HOME="/home/${TARGET_USER}"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    echo "${SSH_PUBLIC_KEY}" > "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"
    log_success "SSH public key registered in ${AUTH_KEYS} with 0600 permissions."
else
    touch "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"
    log_info "Initialized empty authorized_keys file with 0600 permissions."
fi

# Ensure correct ownership of the whole .ssh tree
chown -R "${TARGET_USER}:${TARGET_USER}" "${SSH_DIR}"

# ------------------------------------------------------------------------------
# Sudo Privilege Configuration
# ------------------------------------------------------------------------------
if [[ "${GRANT_SUDO}" = true ]]; then
    # Identify appropriate administrative group
    SUDO_GROUP="sudo"
    if ! getent group sudo >/dev/null 2>&1; then
        if getent group wheel >/dev/null 2>&1; then
            SUDO_GROUP="wheel"
        fi
    fi

    usermod -aG "${SUDO_GROUP}" "${TARGET_USER}"
    log_success "Added '${TARGET_USER}' to administrative group '${SUDO_GROUP}'."

    # Handle Passwordless Sudo Drop-in file
    if [[ "${PASSWORDLESS_SUDO}" = true ]]; then
        SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
        log_info "Configuring passwordless sudo rule in '${SUDOERS_FILE}'..."

        echo "${TARGET_USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "${SUDOERS_FILE}"
        chmod 0440 "${SUDOERS_FILE}"

        # Validate with visudo before committing
        if visudo -cf "${SUDOERS_FILE}" >/dev/null 2>&1; then
            log_success "Sudoers syntax verified successfully."
        else
            log_error "visudo syntax validation FAILED! Revoking rule to prevent lockout."
            rm -f "${SUDOERS_FILE}"
            exit 1
        fi
    fi
fi

# ------------------------------------------------------------------------------
# Provisioning Summary & Notification
# ------------------------------------------------------------------------------
log_header "Provisioning Complete"
printf "  • Username:         %s\n" "${TARGET_USER}"
printf "  • Home Directory:   %s\n" "${USER_HOME}"
printf "  • Login Shell:      %s\n" "${USER_SHELL}"
printf "  • Sudo Access:      %s\n" "$([[ "${GRANT_SUDO}" = true ]] && echo "Enabled" || echo "Disabled")"
printf "  • Passwordless:     %s\n" "$([[ "${PASSWORDLESS_SUDO}" = true ]] && echo "Yes" || echo "No")"
printf "  • SSH Key Installed:%s\n" "$([[ -n "${SSH_PUBLIC_KEY}" ]] && echo "Yes" || echo "No")"
printf "  • Temporary Secret: \033[1;33m%s\033[0m\n" "${GENERATED_PASSWORD}"
printf "  (User will be prompted to reset password immediately upon first login)\n\n"

# Dispatch notification (excluding secret password for security compliance)
send_notification "User Provisioned" "User '${TARGET_USER}' successfully provisioned (Sudo: ${GRANT_SUDO}, SSH: $([[ -n "${SSH_PUBLIC_KEY}" ]] && echo "Yes" || echo "No"))." "SUCCESS" "${WEBHOOK_OVERRIDE}" || true

exit 0
