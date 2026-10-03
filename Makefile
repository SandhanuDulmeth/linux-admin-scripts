# ==============================================================================
# Linux Admin Scripts - Automation Suite Makefile
# ==============================================================================

SHELL := /bin/bash
PREFIX ?= /usr/local
CONFDIR ?= /etc/linux-admin-scripts
LIBDIR ?= $(PREFIX)/lib/linux-admin-scripts
BINDIR ?= $(PREFIX)/bin
SYSTEMD_DIR ?= /etc/systemd/system
LOG_DIR ?= /var/log/linux-admin-scripts

SCRIPTS := $(wildcard bin/*.sh)
LIBRARIES := $(wildcard lib/*.sh)
TESTS := $(wildcard tests/*.sh)

.PHONY: all help lint test install uninstall clean

all: help

help:
	@printf "\033[1;36mLinux Admin Scripts - Management Targets:\033[0m\n"
	@printf "  \033[1;33mmake lint\033[0m       Run ShellCheck static code analysis across all scripts\n"
	@printf "  \033[1;33mmake test\033[0m       Execute the automated regression and unit test suite\n"
	@printf "  \033[1;33mmake install\033[0m    Install binaries, libraries, configs, and systemd units (requires sudo)\n"
	@printf "  \033[1;33mmake uninstall\033[0m  Remove installed components from host system\n"
	@printf "  \033[1;33mmake clean\033[0m      Clean test artifacts and temporary files\n"

lint:
	@printf "\033[1;34m[*] Running ShellCheck static analysis...\033[0m\n"
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x $(SCRIPTS) $(LIBRARIES) $(TESTS); \
		printf "\033[0;32m[+] ShellCheck analysis passed cleanly.\033[0m\n"; \
	else \
		printf "\033[1;33m[!] ShellCheck not found. Install via 'apt install shellcheck' or 'brew install shellcheck'.\033[0m\n"; \
		exit 1; \
	fi

test:
	@printf "\033[1;34m[*] Launching automated test suite...\033[0m\n"
	@bash tests/test_suite.sh

install:
	@printf "\033[1;34m[*] Installing Linux Admin Scripts to $(PREFIX)...\033[0m\n"
	@install -d $(BINDIR)
	@install -d $(LIBDIR)
	@install -d $(CONFDIR)
	@install -d $(SYSTEMD_DIR)
	@install -d -m 755 $(LOG_DIR)
	@install -m 755 bin/backup-engine.sh $(BINDIR)/backup-engine.sh
	@install -m 755 bin/sys-health.sh $(BINDIR)/sys-health.sh
	@install -m 755 bin/log-manager.sh $(BINDIR)/log-manager.sh
	@install -m 755 bin/provision-user.sh $(BINDIR)/provision-user.sh
	@install -m 755 bin/web-deploy.sh $(BINDIR)/web-deploy.sh
	@install -m 644 lib/logger.sh $(LIBDIR)/logger.sh
	@install -m 644 lib/notify.sh $(LIBDIR)/notify.sh
	@if [ ! -f $(CONFDIR)/alerts.conf ]; then \
		install -m 644 config/alerts.conf $(CONFDIR)/alerts.conf; \
		printf "\033[0;32m[+] Created $(CONFDIR)/alerts.conf\033[0m\n"; \
	else \
		printf "\033[1;33m[!] Existing $(CONFDIR)/alerts.conf preserved.\033[0m\n"; \
	fi
	@install -m 644 systemd/sys-health.service $(SYSTEMD_DIR)/sys-health.service
	@install -m 644 systemd/sys-health.timer $(SYSTEMD_DIR)/sys-health.timer
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl daemon-reload; \
		printf "\033[0;32m[+] Systemd daemon reloaded. Enable timer via: systemctl enable --now sys-health.timer\033[0m\n"; \
	fi
	@printf "\033[0;32m[+] Installation completed successfully.\033[0m\n"

uninstall:
	@printf "\033[1;31m[*] Removing Linux Admin Scripts from $(PREFIX)...\033[0m\n"
	@rm -f $(BINDIR)/backup-engine.sh
	@rm -f $(BINDIR)/sys-health.sh
	@rm -f $(BINDIR)/log-manager.sh
	@rm -f $(BINDIR)/provision-user.sh
	@rm -f $(BINDIR)/web-deploy.sh
	@rm -rf $(LIBDIR)
	@rm -f $(SYSTEMD_DIR)/sys-health.service
	@rm -f $(SYSTEMD_DIR)/sys-health.timer
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl daemon-reload; \
	fi
	@printf "\033[0;32m[+] Uninstall completed.\033[0m\n"

clean:
	@rm -rf /tmp/test-suite-* /tmp/backup-engine-*
	@printf "\033[0;32m[+] Cleaned temporary artifacts.\033[0m\n"
