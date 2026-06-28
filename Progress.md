# Progress

Track of current and recent work for session continuity.

## Current Work

No active tasks.

## Completed

- 2026-06-28: Audited update handling across all scripts. Findings: Zabbix Agent (Linux/Windows) already an install/update script; Zabbix Proxy + SQL Server update via apt; TRMM Windows agent auto-updates from server; **TRMM Linux agent was the real gap** (community-compiled from source → server cannot auto-update it).
- 2026-06-28: Created `update-tacticalrmm-agent-linux.sh` — non-interactive, wraps the community script's `update` mode (recompiles rmmagent from amidaware master, hot-swaps binary, mesh/config untouched). Reports version before→after via `rmmagent -version`, optional Discord webhook ($1). `bash -n` clean.
- 2026-06-28: README docs added — TRMM Linux agent "Updating" section, Zabbix proxy apt upgrade, SQL Server CU/apt upgrade. CLAUDE.md repo structure updated with the new script.
- 2026-04-05: Created CLAUDE.md, Onboarding.md, and Progress.md for project documentation and session continuity
- 2026-04-05: Set up auto-onboarding hook to run Onboarding.md on each new session
