# CLAUDE.md - Scripts Repository

**IMPORTANT: At the start of every new session, read and action `Onboarding.md` before doing anything else.**

## Project Overview

Infrastructure automation scripts for deploying and configuring enterprise monitoring (Zabbix), remote management (TacticalRMM), and SQL Server on Linux. All scripts are production-grade, designed for non-interactive deployment via TacticalRMM or interactive standalone use.

## Repository Structure

- `install-zabbix-proxy.sh` / `install-zabbix-proxy-full.sh` — Zabbix proxy installers (Debian 11-13)
- `install-zabbix-agent-linux-tactical-rmm.sh` — Zabbix Agent 2 for Linux (via TacticalRMM)
- `install-zabbix-agent-windows-tactical-rmm.ps1` — Zabbix Agent 2 for Windows (via TacticalRMM)
- `setup-zabbix-discovery.sh` — Zabbix network discovery setup via API
- `install-tacticalrmm-agent-linux.sh` — TacticalRMM agent for Linux (community edition)
- `install-tacticalrmm-agent-windows.ps1` — TacticalRMM agent for Windows
- `install-sqlserver-linux.sh` — Full SQL Server 2025 provisioning on Ubuntu 24.04
- `migrate-ufw-to-iptables.sh` — Firewall migration for SQL Server hosts
- `fix-sql-backup-smb-fatal.sh` — Patch backup automation for robustness

## Script Conventions (MUST follow)

### Structure

- All input collection BEFORE execution — prompt first, execute after confirmation
- `set -eo pipefail` or `set -euo pipefail` at the top of every Bash script
- Helper functions (logging, validation, prompts) at the top of the file
- Clear section headers with visual separators
- 4-space indentation in both Bash and PowerShell

### Output & Logging

- Coloured output: Cyan headers, Green success, Yellow warnings, Red errors
- Box-drawing characters for visual hierarchy in interactive prompts
- Discord webhook notifications on install/upgrade/failure with colour-coded embeds

### Security

- Secret inputs via `read -rsp` (hidden), never stored in script source
- Input validation (regex) before embedding in configs or URLs
- JSON escaping for Discord payloads
- File permissions enforced (`chmod 640`, ACLs) on credential files
- MSI signature verification on Windows

### Error Handling

- Explicit `|| die` or `|| warn` — no silent failures
- Trap handlers for temp file cleanup (`trap 'rm -f ...' EXIT`)
- Dependency checks at start (curl, jq, wget, sqlcmd etc.)

### Idempotency

- Detect existing versions before installing; skip if already correct (unless force flag)
- Back up files before modifying (`.bak` suffix)
- Safe to re-run — scripts handle existing state gracefully

### Service Auto-Detection (Zabbix agent scripts)

- Detect running services: SQL Server, MySQL, PostgreSQL, Nginx, Apache, Docker, Redis, RabbitMQ, IIS
- Configure appropriate Zabbix plugins per detected service
- Disable unneeded loadable plugins to prevent crashes

### TacticalRMM Integration

- Scripts accept TacticalRMM variables as positional arguments
- Variable scopes: Global, Site, Agent (see README.md for full table)
- Credentials come from TacticalRMM variables — never hardcoded, never require manual post-install steps

## Rules

- **ALWAYS keep `Progress.md` up to date** — update it before starting work, after each step, and when decisions or blockers arise. Sessions can end without warning; Progress.md is the only continuity between sessions.
- NEVER add Co-Authored-By, contributor credits, or any attribution to Claude/Anthropic in commits or files
- Scripts must be fully automated — no manual post-install steps; use TacticalRMM variables for credentials
- Always verify documentation and actual system state before making changes — do not guess at config parameters or file paths
- When modifying scripts, preserve the existing output style (colours, box-drawing, section headers)
- Do not add comments, docstrings, or type annotations to code you did not change
- Keep the README.md in sync when adding or modifying scripts

## Onboarding

On each new session, read and action `Onboarding.md` to understand the project context and current state.
