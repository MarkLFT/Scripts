# Progress

Track of current and recent work for session continuity.

## Current Work

No active tasks.

## Completed

- 2026-06-29: VERIFIED WORKING end-to-end on a live agent: 2.10.0 -> 2.11.0, service running. Committed the TRMM bootstrap as `trmm-self-update-bootstrap.sh`, updated README (manual vs TRMM-bootstrap usage, with the self-restart/cgroup explanation) and CLAUDE.md structure.
- 2026-06-29: Found the actual root cause of the exit-1 compile failure (after disproving download/rate-limit and Go-version theories via live diagnostics): the systemd-run transient unit used by the TRMM bootstrap runs with a stripped env and no HOME, so `go build` aborts instantly with "GOCACHE is not defined". Direct build with HOME set succeeds. Fix (commit f3a3612): pin HOME/GOCACHE/GOPATH before compile; drop `--simple` and capture output so real build errors are no longer hidden. go.mod requires go 1.20 (agent has 1.25.6 — version was never the issue).
- 2026-06-29: Debugged fleet-wide TRMM Linux agent update failures. Root cause: community script downloads rmmagent source via single no-retry `wget -q` under `set -e`; transient HTTP error (429 when many agents hit codeload.github.com at once) → exit 8, instant abort, nothing compiled. Confirmed agents on 2.10.0, master=2.11.0 (real update pending), CGO_ENABLED=0 (no gcc needed — red herring). systemd-run detachment + bootstrap worked fine. Fix: pre-fetch source with retry+backoff + neutralise community wget, startup jitter (non-interactive), retry compile once. Commit 1a846c6.
- 2026-06-29: Added systemd-run detachment bootstrap for running the updater from TRMM (the update restarts tacticalagent, which would kill an in-cgroup script). Made pre-flight service detection robust (commit 8233f3d).
- 2026-06-28: Audited update handling across all scripts. Findings: Zabbix Agent (Linux/Windows) already an install/update script; Zabbix Proxy + SQL Server update via apt; TRMM Windows agent auto-updates from server; **TRMM Linux agent was the real gap** (community-compiled from source → server cannot auto-update it).
- 2026-06-28: Created `update-tacticalrmm-agent-linux.sh` — non-interactive, wraps the community script's `update` mode (recompiles rmmagent from amidaware master, hot-swaps binary, mesh/config untouched). Reports version before→after via `rmmagent -version`, optional Discord webhook ($1). `bash -n` clean.
- 2026-06-28: README docs added — TRMM Linux agent "Updating" section, Zabbix proxy apt upgrade, SQL Server CU/apt upgrade. CLAUDE.md repo structure updated with the new script.
- 2026-04-05: Created CLAUDE.md, Onboarding.md, and Progress.md for project documentation and session continuity
- 2026-04-05: Set up auto-onboarding hook to run Onboarding.md on each new session
