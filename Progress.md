# Progress

Track of current and recent work for session continuity.

## Current Work

**Branch `trmm-linux-no-mesh` — drop MeshCentral from the TRMM Linux agent installer, pin the community script.** Code complete; **UNTESTED on a host** (see Blockers).

### Root cause (2026-08-02)

`install-tacticalrmm-agent-linux.sh` was run on a new Debian server and the meshagent did not install.
MeshCentral's `meshinstall.sh` takes `[serverUrl] [deviceGroupId]`; the script passed the server URL only, so it bailed out.
The failure was invisible because the call ended in `>/dev/null 2>&1 || true` and the follow-up check only logged
"status unclear — continuing anyway".

### Decisions

1. **Drop mesh entirely** rather than plumb the device group ID through. TRMM v1.5.0 (15 Jun 2026) added a
   **native web terminal with no MeshCentral dependency** (requires agent 2.11.0+). Take Control and File Browser
   still need mesh — accepted trade for headless servers. Verified against the v1.5.0 release notes.
2. No mesh URL prompt; the `core/settings/` call for `mesh_site` / `mesh_token` is removed.
3. No silent failures — the `|| true` swallowing is gone; every step is fatal with output.
4. **Pin the community build script to a commit** and verify SHA-256 before executing.
5. Pass `--meshnodeid` only when `/opt/tacticalmesh/meshagent` exists.
6. No Zabbix changes (8.0 still beta; nothing here requires touching them).

### The pin

```text
repo:   Nerdy-Technician/LinuxRMM-Script
commit: 8da32b054a39292a114689730dd72540b1b8432c
sha256: d0558e5d2fc8c1a9ca700845296315cdf5081925acbdaf9e84e24f1e8b9fb3cc
```

Verified 2026-08-02: this commit is current `refs/heads/main` HEAD and the checksum matches. Both scripts
carry the same pin and must be re-pinned together.

### Upstream facts verified from source (not assumed)

- `rmmagent` **does** accept `-meshnodeid` (`main.go:53`) and `-m nixmeshnodeid` (`main.go:90`).
- The current official `agent_linux.sh` no longer sets `--meshnodeid` — the handover brief was out of date on
  this point. Harmless: it is still a supported flag, and `SyncMeshNodeID` re-syncs it periodically in svc mode.
- On Linux the agent **never** self-installs mesh (`agent/install.go:161` — `!i.NoMesh && runtime.GOOS != "linux"`),
  so `-nomesh` is unnecessary and omitting `--meshnodeid` registers cleanly with an empty `mesh_node_id`.
- `NixMeshNodeID()` returns `""` safely when `/opt/tacticalmesh/meshagent` is absent (`agent_unix.go:398`).
- **`install -m 0755` does not fail with ETXTBSY over a running binary** (it unlinks first) — verified empirically;
  only `cp` fails. So the old agent does not need removing before the build writes the new binary, and removal
  now happens after every network step, immediately before registration.

### Changes made

- `install-tacticalrmm-agent-linux.sh` — mesh install block and `core/settings/` call removed; community script
  pinned + checksum-verified; used as a **build step only** via two verified dispatcher patches
  (`install_mesh` → no-op, `install_agent` → `install -m 0755 /tmp/temp_rmmagent /usr/local/bin/rmmagent`),
  each asserting exactly one match before and zero after; registration and the systemd unit moved into our
  script; source pre-fetch with retry/backoff and `HOME`/`GOCACHE`/`GOPATH` pinning carried over from the updater;
  run without `--simple` and `tee`d so failures print the tail.
  Side benefit: the auth token and API URL are no longer passed to the third-party script at all.
- `update-tacticalrmm-agent-linux.sh` — same pin and checksum; the source-download `sed` now reports whether it matched.
- `README.md`, `CLAUDE.md` — kept in sync (see below).

### Testing status (2026-08-02)

**Verified in a throwaway Debian 12 container** (the build phase needs no systemd, so it runs in full):

- `bash -n` and shellcheck 0.10.0 clean on both scripts (only the pre-existing benign SC1091).
- Pinned script downloads, SHA-256 matches, **both dispatcher patches report applied** (1 match → 0), source
  pre-fetch used, Go 1.26.1 installed, compile succeeded.
- Binary lands at `/usr/local/bin/rmmagent`, reports **2.11.0** — the version the native terminal needs.
- `/opt/tacticalmesh` does **not** exist and no meshagent binary is present. Mesh is genuinely gone.
- **Negative test passes**: with `COMMUNITY_SHA256` corrupted the run aborts at the checksum, the pre-existing
  agent binary is byte-for-byte untouched, Go is never installed and the source is never fetched — i.e. it
  aborts before executing anything.
- Guard unit tests (8/8) against the shipped `patch_community_script`: applies at exactly 1 match, aborts at
  0 matches (re-patch) and at 2 matches (ambiguous).

**Still outstanding — needs the real Debian host** (nothing below can be done off-host):

1. Registration against the live TRMM server and the systemd unit (`systemctl status tacticalagent` active).
2. Agent appears in TRMM under the right client/site/type.
3. Web terminal connects from the TRMM UI — if not, check the **Use Terminal** role permission first.
4. `update-tacticalrmm-agent-linux.sh` rebuilds and restarts cleanly on the same host with the pinned script.

Then update this section to fully verified with the version it landed on.

### Bugs caught while building this (both fixed)

- `rmmagent -m nixmeshnodeid` returns the literal string `"error getting meshnodeid"` on failure rather than an
  empty value (`agent_unix.go:428`). Without validation that would have been passed straight to `--meshnodeid`
  and recorded silently against the agent. The node id is now shape-validated before use.
- The validation regex was initially written unquoted inside `[[ =~ ]]`, where bash expanded `$_` inside the
  character class and rejected every valid id. Caught by testing the regex rather than eyeballing it; the
  pattern now lives in a variable.

### New: `repair-rmm-zabbix-linux.sh` (branch `rmm-zabbix-repair-script`, stacked on the mesh branch)

Requested 2026-08-02: a script to clean up or repair a client server with a partial RMM and partial Zabbix
install. Diagnoses both stacks, repairs what is safely repairable, and can strip either back to nothing so a
clean install can follow. It never installs an agent — the existing installers do that.

Design decisions:

- **`report` is the default and read-only**, exit 0 = healthy/absent, 1 = problems found, so it doubles as a
  TacticalRMM check. Nothing is removed by accident.
- Destructive actions back up all config to `/var/backups` first, **refuse to touch a stack that looks
  healthy** unless `force` is passed, and refuse to run non-interactively without explicit `yes`. Interactive
  runs require typing `REMOVE`. This is deliberate: a scheduled run that drifts onto a healthy host must not
  wipe a working agent.
- `clean-zabbix` leaves the apt repo (a reinstall needs it); `clean-trmm` leaves `/usr/local/go`.
- Uses `set -uo pipefail` (not `-e`) with explicit `|| die` / `|| warn` throughout, matching the TRMM installer
  and updater — a probe returning non-zero on a broken host is normal input, not a failure.

Key detection worth remembering: the classic Zabbix crash loop is a `plugins.d/*.conf` referencing a loadable
plugin whose package is not installed. `repair` renames those to `.disabled` so the agent starts again.

**Tested** in Debian 12 containers: 9 scenarios / 29 assertions, all passing — clean host, unregistered binary,
missing systemd unit (and its repair), missing binary, build leftovers, empty mesh dir, Zabbix partial config
(missing Server/ServerActive, placeholder creds, missing Include, and the repair of it), destructive-action
refusal + backup + removal, and rejection of an unknown action. The healthy-stack guard was verified separately
(5/5 cases): `yes` will not remove a healthy stack, only `force` will. Container has systemd installed but not
booted, which also confirmed the script degrades sanely when `systemctl` cannot work.

**Not yet exercised on a real host:** anything requiring a live systemd — service restart paths and the
`healthy` state itself.

### Repo-wide audit (folded into this branch/PR at Mark's request)

Requested mid-session; originally staged on a separate `repo-url-doc-fixes` branch, then cherry-picked here so
there is one PR to review. Everything below was verified against the live endpoints, not assumed:

- `install-tacticalrmm-agent-windows.ps1` header usage fetched `install-trmm-agent-windows.ps1` → **404**
  (the same class of bug as the Linux one fixed on the TRMM branch).
- `install-sqlserver-linux.sh` pointed at `sql-server-linux-backups/**main**/install.sh` → **404**; that repo's
  default branch is **master**. Three occurrences, two of them printed to the operator at the end of a run.
- README documented `ZabbixVersion` = `7.4.0` for Windows, but **no 7.4.0 MSI exists on the Zabbix CDN** — the
  documented value fails at download. Changed to `7.4.13` and documented why Linux (major.minor, selects the apt
  repo) and Windows (exact x.y.z, downloads that MSI) differ.

Checked and found healthy: all 11 shell scripts parse and are shellcheck-clean at warning level; both PowerShell
scripts parse; Zabbix Linux repo URL patterns and the Windows MSI pattern resolve; the Windows MSI signature
check is present. Non-issues: `PROXY_MODE`/`DB_TYPE` in `install-zabbix-proxy.sh` are vestigial constants
documenting hardcoded choices (the config writes `ProxyMode=0` literally) — cosmetic only; SC2076 in
`migrate-ufw-to-iptables.sh` is a literal substring match, which is the intended behaviour.

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
