# 🐧 Linux Admin Scripts — Enterprise Automation Suite

[![CI & Static Analysis](https://github.com/sandhanu/linux-admin-scripts/actions/workflows/lint.yml/badge.svg)](https://github.com/sandhanu/linux-admin-scripts/actions/workflows/lint.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-100%25%20Compliant-brightgreen.svg)](https://www.shellcheck.net/)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-blue.svg)](https://www.gnu.org/software/bash/)
[![Systemd](https://img.shields.io/badge/Systemd-Native%20Timers-red.svg)](https://systemd.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A production-grade Linux systems engineering and Site Reliability Engineering (SRE) automation suite. 

Unlike ad-hoc shell scripts, this repository follows strict enterprise engineering principles: **defensive bash execution (`set -euo pipefail`)**, **signal exit traps**, **shared modular libraries**, **pre-flight disk validation**, **SHA-256 cryptographic verification**, **structured JSON telemetry**, and **modern systemd timer daemons**.

---

## 🏗️ Repository Architecture

```text
linux-admin-scripts/
├── .github/
│   └── workflows/
│       └── lint.yml          # GitHub Actions running ShellCheck & automated tests
├── bin/
│   ├── backup-engine.sh      # Backup with compression, SHA-256 verification & retention
│   ├── sys-health.sh         # System metrics, threshold alerts & structured JSON
│   ├── log-manager.sh        # Log copytruncate rotation, incident analyzer & pruning
│   ├── provision-user.sh     # Hardened user creation, SSH key setup & visudo rules
│   └── web-deploy.sh         # Nginx virtual host, security headers & UFW firewall
├── config/
│   └── alerts.conf           # Global alert thresholds, backup paths & webhooks
├── lib/
│   ├── logger.sh             # Modular colored logging (INFO, OK, WARN, ERROR, DEBUG)
│   └── notify.sh             # Webhook dispatcher (Slack, Discord, generic JSON API)
├── systemd/
│   ├── sys-health.service    # Sandboxed systemd oneshot service unit
│   └── sys-health.timer      # Precision systemd timer with randomized jitter
├── tests/
│   └── test_suite.sh         # Automated unit & integration regression harness
├── Makefile                  # make install, make test, make lint, make clean
└── README.md                 # Technical documentation & operational guide
```

---

## 📐 Enterprise Engineering Standards

```
                      ┌─────────────────────────────────────────┐
                      │          Execution Invocation           │
                      └────────────────────┬────────────────────┘
                                           │
                        ┌──────────────────▼──────────────────┐
                        │       1. Strict Mode Flags          │
                        │       set -euo pipefail             │
                        └──────────────────┬──────────────────┘
                                           │
         ┌─────────────────────────────────┼─────────────────────────────────┐
         │                                 │                                 │
┌────────▼─────────┐             ┌─────────▼────────┐              ┌─────────▼────────┐
│ 2. Signal Traps  │             │ 3. Shared Libs   │              │ 4. Pre-Flights   │
│ EXIT, INT, TERM  │             │ logger & notify  │              │ Disk & Auth Val  │
└────────┬─────────┘             └─────────┬────────┘              └─────────┬────────┘
         │                                 │                                 │
         └─────────────────────────────────┼─────────────────────────────────┘
                                           │
                        ┌──────────────────▼──────────────────┐
                        │      Atomic Idempotent Run          │
                        │      + SHA-256 / JSON Output        │
                        └─────────────────────────────────────┘
```

### I. Strict Bash Defensive Mode
Every script begins with strict error enforcement:
```bash
set -euo pipefail
```
* **`-e`**: Immediately terminates execution if any command exits with a non-zero status, preventing cascading failures.
* **`-u`**: Treats undefined variables as fatal errors, preventing accidental operations on unbound variables like `rm -rf "${UNSET_VAR}/"`.
* **`-o pipefail`**: Inherits the exit code of the first failing command in a pipeline, rather than masking failures with trailing commands.

### II. Exit Traps & Signal Interruption Safety
Processes allocate ephemeral scratch spaces and register cleanup routines:
```bash
TMP_WORK_DIR=$(mktemp -d -t backup-engine-XXXXXX)
cleanup() {
    local exit_code=$?
    rm -rf "${TMP_WORK_DIR}"
    # Dispatches critical failure webhooks on unexpected aborts
}
trap cleanup EXIT INT TERM
```

### III. Shared Modular Libraries (`lib/`)
Reusable logic is decoupled into standalone modules:
* **`lib/logger.sh`**: ANSI color styling with automatic TTY detection (suppresses escape characters when piped to files/CI), standard error (`>&2`) routing for `log_error`, and level filtering (`DEBUG < INFO < WARN < ERROR`).
* **`lib/notify.sh`**: Dispatches webhook notifications to Slack, Discord, or generic APM endpoints with non-blocking timeout safeguards (`--max-time 15`).

### IV. Dynamic CLI Argument Parsing & Dry-Run Modes
All tools support dynamic flags via `getopts`, rigorous regex input validation, and dry-run execution (`-n` or `-t`) to test operations without modifying disk state:
```bash
while getopts "s:d:r:w:nvh" opt; do
  case "${opt}" in
    s) SOURCE_DIR="${OPTARG}" ;;
    d) DEST_DIR="${OPTARG}" ;;
    n) DRY_RUN=true ;;
  esac
done
```

---

## 🛠️ Tool Suite Deep Dive

### 1. Enterprise Backup Engine (`bin/backup-engine.sh`)
Automates host backups with defense-in-depth safety checks.

* **Disk Capacity Pre-flight**: Verifies target filesystem space against `(source_size * 1.15)` using `du` and `df -P` before starting compression, eliminating "disk full" panics.
* **Cryptographic Integrity**: Emits a `sha256sum` signature alongside the archive and runs an immediate verification pass (`sha256sum -c`).
* **Automated Pruning**: Enforces retention policies via `find ... -mtime +N` to eliminate expired archives and their checksum counterparts.

```bash
# Production execution: back up /etc/nginx to /var/backups with a 14-day retention policy
sudo ./bin/backup-engine.sh -s /etc/nginx -d /var/backups -r 14

# Dry-run validation (verifies disk space and permissions without writing files)
./bin/backup-engine.sh -s /var/www/app -n
```

### 2. System Health Guardian (`bin/sys-health.sh`)
Continuously monitors physical host metrics against SLA thresholds configured in `config/alerts.conf`.

* **Metrics Monitored**: 
  * CPU Utilization % (high-precision 0.2s delta calculation via `/proc/stat`)
  * Physical RAM Utilization % (active vs available parsed from `/proc/meminfo`)
  * Root Disk Usage % (`df -P /`)
  * 1-Minute Host Load Average relative to core count (`/proc/loadavg` vs `nproc`)
* **Dual Output Modes**: Color-formatted CLI dashboard for engineers, or structured JSON for observability ingestion (Datadog, Vector, Loki, Prometheus textfile collector).

```bash
# Human-readable status dashboard
./bin/sys-health.sh

# Structured JSON telemetry
./bin/sys-health.sh -j | jq .

# Append JSON telemetry directly to a rotation target
./bin/sys-health.sh -l /var/log/linux-admin-scripts/sys-health.log
```

**Sample JSON Output:**
```json
{
  "timestamp": "2026-10-03T12:00:00Z",
  "hostname": "prod-api-01",
  "cpu_pct": 28,
  "mem_pct": 64,
  "disk_pct": 72,
  "load_1m": "0.45",
  "cpu_cores": 4,
  "status": "HEALTHY",
  "breaches": []
}
```

### 3. Log Lifecycle & Incident Analyzer (`bin/log-manager.sh`)
Prevents unmanaged disk consumption and serves as an incident response CLI.

* **Copytruncate Rotation**: Safely zeros active logs (`truncate -s 0`) without closing file descriptors or interrupting active server daemons.
* **Gzip Compression**: Archives rotated historical logs with `.gz` compression.
* **Rapid Incident Forensics (`-a`)**:
  * Counts total CRITICAL, ERROR, and WARN log events.
  * Aggregates and displays the top 5 recurring error signatures.
  * Extracts top originating client IPs.
  * Summarizes HTTP status code distributions (4xx / 5xx).

```bash
# Incident forensic analysis on an active Nginx or application log
./bin/log-manager.sh -l /var/log/nginx/access.log -a

# Rotate when log exceeds 100MB, prune archives older than 30 days
sudo ./bin/log-manager.sh -l /var/log/app/backend.log -s 100 -r 30
```

### 4. Hardened User Provisioner (`bin/provision-user.sh`)
Automates zero-trust user provisioning for operators and CI/CD agents.

* **Secure Credentials**: Generates a 24-character cryptographic password via `openssl rand -base64 18`.
* **Zero-Trust Login**: Forces instant password revocation on first login (`chage -d 0`).
* **SSH Hardening**: Sets up `.ssh/authorized_keys` with strict permissions (`0700` directory, `0600` file).
* **Safe Sudoers Drop-In**: Writes isolated `/etc/sudoers.d/<username>` rules and verifies syntax with `visudo -cf` prior to activation, rolling back instantly on error.

```bash
# Provision a standard engineering account with an authorized public key
sudo ./bin/provision-user.sh -u developer -k "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..." -s

# Provision a passwordless CI/CD service account
sudo ./bin/provision-user.sh -u github-runner -k ~/.ssh/id_rsa.pub -p
```

### 5. Production Web Deployer (`bin/web-deploy.sh`)
Provisions hardened Nginx virtual hosts with integrated security headers and firewall policies.

* **Security Headers**: Injects `X-Frame-Options`, `X-Content-Type-Options`, `Content-Security-Policy`, and `Referrer-Policy`.
* **Firewall Hardening**: Configures UFW with **anti-lockout SSH guards** (`ufw allow OpenSSH`) before opening HTTP ports.
* **Service Verification**: Runs `nginx -t` validation, performs an atomic systemd reload (`systemctl reload nginx`), and verifies HTTP responses via curl.

```bash
# Deploy a virtual host on port 80 with UFW firewall protection
sudo ./bin/web-deploy.sh -d dashboard.internal.net -s

# Deploy an isolated internal microservice on port 8080
sudo ./bin/web-deploy.sh -d api.internal -p 8080 -r /opt/web/api/html
```

---

## ⏱️ Modern Systemd Integration (Replacing Crontab)

Crontab lacks observability, process sandboxing, and execution jitter. This suite provides native systemd unit definitions:

* **`systemd/sys-health.service`**: Executes health checks inside an isolated cgroup with `ProtectSystem=strict` and `NoNewPrivileges=true`.
* **`systemd/sys-health.timer`**: Triggers execution every 5 minutes, introduces `RandomizedDelaySec=15s` to avoid thundering-herd spikes across fleet nodes, and retains `Persistent=true` to catch up on missed boots.

```bash
# 1. Install service & timer
sudo make install

# 2. Enable and start the timer daemon
sudo systemctl enable --now sys-health.timer

# 3. Inspect timer schedule and execution history
systemctl list-timers sys-health.timer
journalctl -u sys-health.service -f
```

---

## 🧪 Testing & CI/CD Validation

### Automated Local Test Suite
Run the regression harness across all scripts and libraries without external dependencies:

```bash
make test
```

**Test Coverage Includes:**
* Static syntax verification via `bash -n`
* Logging level thresholds and `stderr` stream separation
* Notification fallback behavior when webhooks are offline
* Backup engine dry-run and full SHA-256 checksum generation
* System health JSON schema validation
* Log manager pattern recognition and copytruncate execution
* User provisioner and web deployment test simulations

### ShellCheck Linting
Enforce strict POSIX and ShellCheck standards:

```bash
make lint
```

---

## 📦 Installation & Uninstallation

```bash
# Clone the repository
git clone https://github.com/sandhanu/linux-admin-scripts.git
cd linux-admin-scripts

# Install to /usr/local/bin, /usr/local/lib, and /etc/linux-admin-scripts
sudo make install

# Remove all installed binaries, libraries, and systemd units
sudo make uninstall
```

---

## 💼 Why This Stands Out in DevOps & SRE Interviews

| Engineering Feature | Production Competency Demonstrated |
| :--- | :--- |
| **`lib/` Modularity** | DRY (Don't Repeat Yourself) system architecture and reusable library design. |
| **`set -euo pipefail` & Traps** | Deep understanding of UNIX process lifecycles, signal handling (`SIGTERM`/`SIGINT`), and failure containment. |
| **Pre-Flight Disk Verifications** | Defensive systems engineering: preventing disk outages before starting operations. |
| **SHA-256 Checksumming** | Cryptographic data integrity verification in backup pipelines. |
| **Structured JSON Telemetry** | Cloud-native observability mindset (ready for Datadog, Prometheus, Vector). |
| **Copytruncate Log Rotation** | In-depth knowledge of Linux file descriptors, active inode operations, and daemon stability. |
| **Systemd Timers & Sandboxing** | Modern Linux service management with cgroup security sandboxing (`ProtectSystem=strict`). |
| **CI/CD Static Analysis** | Shift-left testing, ShellCheck enforcement, and automated quality gates. |

---

## 📄 License
This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
