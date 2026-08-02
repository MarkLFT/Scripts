# Scripts

Collection of Scripts for Regular Tasks

---

## Zabbix

### Zabbix Proxy

Install a Zabbix proxy onto a Debian host to act as a remote proxy to talk to a central Zabbix server.
Supports: Debian 11 (Bullseye), Debian 12 (Bookworm), Debian 13 (Trixie)

#### Lite Version

Fixed settings: Active mode, SQLite3 database, performance tuned for a small LAN (~12 agents).
Prompts for: Zabbix version, proxy hostname, server address, and PSK encryption.

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy.sh -o /tmp/install-zabbix-proxy.sh && sudo bash /tmp/install-zabbix-proxy.sh
```

#### Full Version

Prompts for all settings including proxy mode, database type (SQLite3/MySQL/PostgreSQL), and performance tuning.

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy-full.sh -o /tmp/install-zabbix-proxy-full.sh && sudo bash /tmp/install-zabbix-proxy-full.sh
```

#### Updating the proxy

The installer adds the official Zabbix apt repository, so minor/patch updates **within the installed major version** are handled by apt — no re-run of the installer is needed:

```bash
sudo apt-get update
sudo apt-get install --only-upgrade 'zabbix-proxy*' 'zabbix-sql-scripts'
sudo systemctl restart zabbix-proxy
```

To move to a **new major version** (e.g. 7.0 → 7.4), the repository definition itself must change. Re-run the installer and enter the new version when prompted — it adds the new repo and upgrades in place.

> The systemd unit is **`zabbix-proxy`** whichever database backend you chose — all three packages (`zabbix-proxy-sqlite3`, `-mysql`, `-pgsql`) ship the same `zabbix-proxy.service`. There is no `zabbix-proxy-sqlite3.service`.

##### ICMP checks need fping

The proxy uses `fping` for all `icmpping*` items, and Zabbix looks for it at `/usr/sbin/fping` by default — but Debian and Ubuntu install it to `/usr/bin/fping`. The installer now adds the package and writes the detected path into the config.

Proxies built before that change have neither, so **every ping check behind them fails silently** while the log fills with `At least one of '/usr/sbin/fping', '/usr/sbin/fping6' must exist`. To check and fix an existing proxy:

```bash
command -v fping; grep -E '^Fping' /etc/zabbix/zabbix_proxy.conf   # both empty = affected

sudo apt-get install -y fping
printf '\nFpingLocation=/usr/bin/fping\nFping6Location=/usr/bin/fping6\n' | sudo tee -a /etc/zabbix/zabbix_proxy.conf
sudo systemctl restart zabbix-proxy
```

### Zabbix Agent

Installs Zabbix Agent 2 on systems to be monitored. Configures it to connect to a local proxy.
Designed to be run from within TacticalRMM — obtains values from site and global variables.
Will auto-detect monitorable services (SQL Server, MySQL, PostgreSQL, Nginx, Apache, Docker, Redis, RabbitMQ) and configure the appropriate plugin.
When SQL Server is detected the script installs the MSSQL loadable plugin, creates the `zabbix` SQL login with the required permissions (including msdb grants for SQL Agent job monitoring), and writes live credentials into the plugin config — no manual post-install steps required.
When Redis is detected the script installs the Redis loadable plugin and writes the session config.
When RabbitMQ is detected the script enables the management plugin and creates the `zbx_monitor` monitoring user (RabbitMQ uses HTTP-based monitoring via the Zabbix template, not an agent plugin).
Sends a Discord notification on install or upgrade.

#### TacticalRMM Variables Required

| Variable               | Scope  | Example                                |
| ---------------------- | ------ | -------------------------------------- |
| `ZabbixProxy`          | Site   | `10.10.1.5`                            |
| `ZabbixServer`         | Site   | `10.10.0.10`                           |
| `DiscordWebhook`       | Global | `https://discord.com/api/webhooks/...` |
| `ZabbixVersion`        | Global | `7.4` (Linux) / `7.4.13` (Windows)     |
| `ZabbixMSSQLPassword`  | Global | Password for the `zabbix` SQL login    |
| `MSSQLSAPassword`      | Site   | SA password (Linux only)               |
| `ZabbixHostName`       | Agent  | Custom Zabbix hostname (optional)      |

> **`ZabbixVersion` differs by platform.** Linux takes **major.minor** (`7.4`) — it selects the apt repository, and apt then installs the newest patch release. Windows takes a **full x.y.z** version because it downloads that exact MSI from the Zabbix CDN, so it must be a patch release that actually exists — check [cdn.zabbix.com/zabbix/binaries/stable](https://cdn.zabbix.com/zabbix/binaries/stable/). Note there is no `7.4.0` MSI published; the value must be a real release such as `7.4.13`, or the download fails.

#### Linux Agent

Via TacticalRMM with site variables:

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux-tactical-rmm.sh | sudo bash -s -- "{{site.ZabbixProxy}}" "{{site.ZabbixServer}}" "{{global.DiscordWebhook}}" "{{global.ZabbixVersion}}" "{{global.ZabbixMSSQLPassword}}" "{{site.MSSQLSAPassword}}" "{{agent.ZabbixHostName}}"
```

Manual use with real values:

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux-tactical-rmm.sh | sudo bash -s -- "10.10.1.5" "10.10.0.10" "https://discord.com/api/webhooks/..." "7.4" "ZabbixMSSQLPass!" "SAPassword!" "My SQL Server"
```

Force reconfigure (skips repo/install, rewrites all configs and recreates SQL logins):

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux-tactical-rmm.sh | sudo bash -s -- "{{site.ZabbixProxy}}" "{{site.ZabbixServer}}" "{{global.DiscordWebhook}}" "{{global.ZabbixVersion}}" "{{global.ZabbixMSSQLPassword}}" "{{site.MSSQLSAPassword}}" "{{agent.ZabbixHostName}}" "force"
```

#### Windows Agent (Zabbix)

Via TacticalRMM (recommended):

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows-tactical-rmm.ps1))) -ZabbixProxy "{{site.ZabbixProxy}}" -ZabbixServer "{{site.ZabbixServer}}" -DiscordWebhook "{{global.DiscordWebhook}}" -ZabbixVersion "{{global.ZabbixVersion}}" -ZabbixMSSQLPassword "{{global.ZabbixMSSQLPassword}}" -ZabbixHostName "{{agent.ZabbixHostName}}"
```

Manual use — download first then run:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows-tactical-rmm.ps1 -OutFile "$env:TEMP\install-zabbix-agent-windows-tactical-rmm.ps1"
& "$env:TEMP\install-zabbix-agent-windows-tactical-rmm.ps1" -ZabbixProxy "10.10.1.5" -ZabbixServer "10.10.0.10" -DiscordWebhook "https://discord.com/api/webhooks/..." -ZabbixVersion "7.4.13" -ZabbixMSSQLPassword "ZabbixMSSQLPass!" -ZabbixHostName "My SQL Server"
```

Force reconfigure (skips MSI download/install, rewrites all configs and recreates SQL logins):

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows-tactical-rmm.ps1))) -ZabbixProxy "{{site.ZabbixProxy}}" -ZabbixServer "{{site.ZabbixServer}}" -DiscordWebhook "{{global.DiscordWebhook}}" -ZabbixVersion "{{global.ZabbixVersion}}" -ZabbixMSSQLPassword "{{global.ZabbixMSSQLPassword}}" -ZabbixHostName "{{agent.ZabbixHostName}}" -Force
```

### Zabbix Discovery

Sets up automatic network discovery of devices that either have the Zabbix agent installed or have SNMP configured.
Connects to the Zabbix API, fetches proxies and host groups, and creates the discovery rule and auto-add actions.

**Checks performed:** Zabbix agent (port 10050), SNMPv2c (port 161), SNMPv1 (port 161)
**Prompts for:** Zabbix server URL, API credentials, proxy, IP range, scan interval, SNMP community string, host groups.
**Templates** are not assigned automatically — apply them manually after discovery.

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/setup-zabbix-discovery.sh \
  -o /tmp/setup-zabbix-discovery.sh && bash /tmp/setup-zabbix-discovery.sh
```

### Zabbix SQL Server

The Zabbix Agent 2 MSSQL plugin monitors SQL Server instances via a dedicated SQL login. The agent install scripts handle everything automatically when the `ZabbixMSSQLPassword` variable is set (and `MSSQLSAPassword` on Linux):

1. Installs the `zabbix-agent2-plugin-mssql` loadable plugin package
2. Creates (or updates) the `zabbix` SQL login with the provided password
3. Grants server-level permissions: `VIEW SERVER STATE`, `VIEW ANY DEFINITION`
4. Grants msdb permissions for SQL Agent job monitoring (`sysjobs`, `sysjobactivity`, `sysjobservers`, `agent_datetime`)
5. Writes live credentials into the plugin config at `plugins.d/mssql.conf`
6. Disables all loadable plugins not needed for detected services (prevents crashes from e.g. NVIDIA plugin on a server without a GPU)
7. Adds the `plugins.d/` Include directive to the main agent config

No manual post-install steps are required.

On Windows the script uses Windows Authentication (trusted connection as SYSTEM) to create the SQL login, so no SA password is needed. On Linux, the `MSSQLSAPassword` site variable is required to authenticate to SQL Server via `sqlcmd`.

#### Plugin Config Location

Session credentials are written into the package-installed plugin config, not a separate file:

| OS | Config file path |
| --- | --- |
| Linux | `/etc/zabbix/zabbix_agent2.d/plugins.d/mssql.conf` |
| Windows | `C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\plugins.d\mssql.conf` |

#### Apply the Zabbix Template

In the Zabbix frontend, assign the **MSSQL by Zabbix agent 2** template to the host. This template provides out-of-the-box items, triggers, and dashboards for SQL Server monitoring.

---

## TacticalRMM

### TacticalRMM Agent

Installs the TacticalRMM agent on a host and registers it with your TacticalRMM server.
Connects to the TacticalRMM API to fetch available clients and sites so you can pick from a list — no need to look up IDs manually.

**Prompts for:** TacticalRMM API URL, API key, client (list), site (list), agent type (Server/Workstation).

> **API Key:** Generate in TacticalRMM under Settings → Global Settings → API Keys → Add API Key.
> The key is entered interactively and never stored in the script.

#### Linux Agent (Ubuntu / Debian)

Installs the **TacticalRMM agent** only — monitoring, scripts, tasks, patch management, and the native web terminal. **The MeshCentral agent is not installed** (see [MeshCentral on Linux](#meshcentral-on-linux) below).

The agent binary is compiled from the official [amidaware/rmmagent](https://github.com/amidaware/rmmagent) source using Go. The build is driven by the community script originally created by [netvolt](https://github.com/netvolt/LinuxRMM-Script) and maintained by [Nerdy-Technician](https://github.com/Nerdy-Technician/LinuxRMM-Script), which is **pinned to a specific commit and SHA-256 verified before it is executed** — a moving branch head is not fetched. It is used purely as a build step: its mesh install is patched out and its registration/service setup is replaced, so registration and the systemd unit are handled by this script and the auth token is never passed to third-party code. Each patch asserts it matched exactly once, and the install aborts if upstream has changed shape.

Compilation takes a few minutes on first run — this is normal.

> **Note:** This script targets the **community (free) licence**. Prebuilt Linux and macOS agents require a Tier 1 sponsorship (see [code signing](https://docs.tacticalrmm.com/code_signing/)), so compiling from source is the supported route here.
>
> **Auth Token (Linux only):** In TacticalRMM go to Agents → Install Agent → select Windows → Manual installation
> → click Show Manual Instructions → copy the value after `--auth`.
> This token is used to register the agent and can be reused for multiple installs until it expires.

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-tacticalrmm-agent-linux.sh \
  -o /tmp/install-tacticalrmm-agent-linux.sh && sudo bash /tmp/install-tacticalrmm-agent-linux.sh
```

After installation verify the service is running and check the version:

```bash
systemctl status tacticalagent
/usr/local/bin/rmmagent -version
```

##### MeshCentral on Linux

This installer does not install the MeshCentral agent. Previously it tried to, but the install silently failed: MeshCentral's `meshinstall.sh` takes `[serverUrl] [deviceGroupId]` and only the server URL was being passed, so it bailed out — and the error was swallowed.

Rather than plumb the device group ID through, mesh was dropped. As of **TRMM v1.5.0** the web terminal is fully native with **no MeshCentral dependency** (it requires agent **2.11.0+**), which covers day-to-day shell access on headless servers.

**What still works without mesh:**

- Monitoring, checks, tasks, scripts, patch management
- The native web terminal (TRMM v1.5.0+, agent 2.11.0+)

**What does not:**

- **Take Control** (remote desktop) and **File Browser** — both still MeshCentral-backed. They are slated to be reimplemented natively in future releases, the terminal being the first of the three to land.

> **Terminal access is a separate role permission.** It moved from *Use MeshCentral* to **Role → Agents → Use Terminal**. If the terminal will not connect, check this before suspecting the agent.

**To add MeshCentral back on a host that needs Take Control or File Browser:**

1. In MeshCentral, open the device group → **Add Agent** → **Installation Executable** for Linux/BSD/macOS. The URL it gives you contains `?id=<deviceGroupId>` — the server URL on its own is not enough, which is exactly what caused the original failure.
2. Run that installer on the host.
3. Re-run `install-tacticalrmm-agent-linux.sh`. It detects `/opt/tacticalmesh/meshagent`, reads the node id with `rmmagent -m nixmeshnodeid`, and links it to the agent record with `--meshnodeid`. If no mesh agent is present it simply says so and registers without it.

##### Re-pinning the community script

Both `install-tacticalrmm-agent-linux.sh` and `update-tacticalrmm-agent-linux.sh` pin the same commit and checksum. To move the pin, get the current head and its checksum:

```bash
git ls-remote https://github.com/Nerdy-Technician/LinuxRMM-Script.git refs/heads/main
curl -fsSL https://raw.githubusercontent.com/Nerdy-Technician/LinuxRMM-Script/<commit>/rmmagent-linux.sh | sha256sum
```

Review the upstream diff first, then update `COMMUNITY_COMMIT` and `COMMUNITY_SHA256` in **both** scripts — they must stay in step. A checksum mismatch, or a dispatcher patch that no longer matches exactly once, aborts the run before anything is executed.

##### Updating the Linux agent

Because the Linux agent is **compiled from source** (community edition), the TacticalRMM server cannot push agent updates to it the way it does for the official signed Windows agent. The `rmmagent` binary never updates on its own — it will silently drift behind the server version until it is rebuilt. (Where a MeshCentral agent has been added separately, that component self-updates from the mesh server; nothing to do for it.)

`update-tacticalrmm-agent-linux.sh` rebuilds the agent: it records the current version, recompiles `rmmagent` from the latest [amidaware/rmmagent](https://github.com/amidaware/rmmagent) source via the pinned community script's `update` mode, hot-swaps the binary, and verifies the service. All agent configuration is left untouched, as is any mesh agent. It is non-interactive and safe to re-run.

**Manual / SSH (interactive):**

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/update-tacticalrmm-agent-linux.sh \
  -o /tmp/update-trmm-agent-linux.sh && sudo bash /tmp/update-trmm-agent-linux.sh
```

**From TacticalRMM (use the bootstrap — do NOT pipe the updater straight to bash):**

The update restarts the `tacticalagent` service — the very service running the script. A script launched by the agent shares the agent's systemd cgroup, so stopping the agent would kill the update mid-run and could leave the agent offline. Use `trmm-self-update-bootstrap.sh`, which launches the updater **detached** via `systemd-run` so it survives the restart, and returns immediately so TacticalRMM records success.

In **Settings → Script Manager → New** (type **Shell**, no sudo — the agent runs as root), paste the contents of [`trmm-self-update-bootstrap.sh`](trmm-self-update-bootstrap.sh) and set the script argument to `{{global.DiscordWebhook}}` (optional). Then run it on-demand or as a scheduled task.

Follow progress on a host, and confirm the new version:

```bash
journalctl -u trmm-self-update -f
/usr/local/bin/rmmagent -version | head -1
```

> **Tip:** Add the bootstrap as a scheduled TacticalRMM task so the community agent tracks the server version over time. Each run pre-fetches the source with retries and compiles in a few minutes; a transient GitHub error is retried rather than aborting the run.

#### Windows Agent (TacticalRMM)

Uses the TacticalRMM deployment API to generate the installer automatically — no auth token needed.

Run as Administrator:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-tacticalrmm-agent-windows.ps1 -OutFile "$env:TEMP\install-tacticalrmm-agent-windows.ps1"
& "$env:TEMP\install-tacticalrmm-agent-windows.ps1"
```

---

## Repair & Cleanup

### RMM / Zabbix Repair (Linux)

`repair-rmm-zabbix-linux.sh` diagnoses and repairs a client server left half-installed by an interrupted or failed TacticalRMM agent or Zabbix Agent 2 install, and can strip either stack back to nothing so a clean install can follow. It never installs either agent — use the dedicated installers for that.

**Actions:**

| Action | What it does |
| ------ | ------------ |
| `report` | Read-only diagnosis (**default**). Exit `0` = healthy or absent, `1` = problems found — so it works as a TacticalRMM check |
| `repair` | Fixes what can be fixed safely, then re-reports |
| `clean-trmm` | Removes all TacticalRMM agent components (including MeshCentral) |
| `clean-zabbix` | Removes all Zabbix Agent 2 components |
| `clean-all` | Both |

**What it detects.** For the RMM agent: binary present but never registered, config present with the binary missing, a missing or orphaned systemd unit, a failed service, an empty `/opt/tacticalmesh` left by a failed mesh install, and stale build leftovers in `/tmp`. For Zabbix: a half-installed package, a broken dpkg state, the legacy v1 `zabbix-agent` sitting alongside Agent 2 (they fight over port 10050), a config missing `Server=`/`ServerActive=`/`Hostname=`, a missing `plugins.d` Include, `CHANGE_ME` placeholder credentials, the apt repo added without the agent, and — the classic crash loop — **plugin configs referencing a loadable plugin whose package is not installed**.

**What `repair` fixes automatically:** reconciles a broken dpkg state, recreates the missing `tacticalagent` systemd unit, starts services that should be running, disables orphaned plugin configs that crash the agent, adds the missing `plugins.d` Include, and clears stale build leftovers. Anything it cannot fix safely is reported with a suggested next step.

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/repair-rmm-zabbix-linux.sh \
  -o /tmp/repair-rmm-zabbix-linux.sh && sudo bash /tmp/repair-rmm-zabbix-linux.sh
```

Run with no arguments it prompts for the action. Via TacticalRMM, pass them positionally:

```bash
# Diagnosis only — usable as a scheduled check (exit 1 = problems found)
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/repair-rmm-zabbix-linux.sh | sudo bash -s -- "report" "{{global.DiscordWebhook}}"

# Repair
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/repair-rmm-zabbix-linux.sh | sudo bash -s -- "repair" "{{global.DiscordWebhook}}" "yes"
```

| Argument | Purpose |
| -------- | ------- |
| `$1` | Action — `report` (default), `repair`, `clean-trmm`, `clean-zabbix`, `clean-all` |
| `$2` | Discord webhook URL (optional) |
| `$3` | `yes` to confirm a destructive action non-interactively; `force` to also allow cleaning a stack that looks healthy |

> **Safety.** `report` is the default and is read-only, so nothing is removed by accident. Every destructive action writes a timestamped configuration backup to `/var/backups` first. A `clean-*` action **refuses to touch a stack that looks healthy** unless `force` is given, so a stray scheduled run cannot wipe a working agent — and a non-interactive run with no confirmation is refused outright. Interactively it requires typing `REMOVE`.
>
> `clean-zabbix` deliberately leaves the Zabbix apt repository configured, since a reinstall needs it. `clean-trmm` leaves the Go toolchain at `/usr/local/go` in place.

---

## SQL Server

### SQL Server on Linux (Ubuntu 24.04) — Server Setup

Provisioning script for a dedicated SQL Server 2025 instance on Ubuntu 24.04 LTS.
Installs SQL Server, configures MSDTC, replaces UFW with iptables, and hardens the OS.

Backup automation is handled separately by [sql-server-linux-backups](https://github.com/MarkLFT/sql-server-linux-backups) — run that installer after this script completes and the server is rebooted.

Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-sqlserver-linux.sh -o /tmp/install-sqlserver-linux.sh && sudo bash /tmp/install-sqlserver-linux.sh
```

#### What it does

| Step | Description |
| ---- | ----------- |
| 0 | Sets the hostname to `<name>.rmserver.local` |
| 1 | Installs SQL Server 2025, sqlcmd (mssql-tools18), configures collation, data/log/backup directories, memory limit, and enables SQL Server Agent (except Express) |
| 2 | Configures MSDTC with fixed RPC and DTC ports |
| 3 | Captures existing UFW rules as native iptables rules |
| 4 | Adds iptables rules for SQL Server (1433), MSDTC ports, and NAT PREROUTING for port 135 |
| 5 | Installs iptables-persistent and saves all rules |
| 6 | Removes UFW and rebuilds a clean iptables ruleset (INPUT DROP policy, SSH/SQL/MSDTC allowed) |
| 7 | *(Backup — handled by [sql-server-linux-backups](https://github.com/MarkLFT/sql-server-linux-backups))* |
| 8 | Installs and activates the TuneD `mssql` profile (Microsoft-recommended kernel tuning) |
| 9 | Installs and configures chrony for NTP time synchronisation |
| 10 | Enables unattended security updates (security patches only, no auto-reboot) |
| 11 | Hardens SSH (disables root login, password auth; sets banner) — optional |
| 12 | Installs fail2ban with an SSH jail and optional IP whitelist |

#### Interactive prompts

All settings are collected before any changes are made. A summary is displayed for confirmation.

| Prompt | Default | Description |
| ------ | ------- | ----------- |
| Hostname | `db` | Short hostname — FQDN becomes `<hostname>.rmserver.local` |
| License type | Developer | Evaluation, Developer, Express, Standard, or Enterprise |
| Server collation | `SQL_Latin1_General_CP1_CI_AI` | SQL Server collation |
| Data directory | `/sqldata` | Default data file location |
| Log directory | `/sqllog` | Default log file location |
| Backup directory | `/sqlbackup` | Default backup file location |
| SA password | *(none)* | Must meet SQL Server complexity rules (>=8 chars, 3-of-4 categories) |
| Memory limit | 85% of detected RAM | SQL Server memory cap in MB (minimum 2048) |
| MSDTC ports | 13500 / 51999 | RPC and DTC TCP ports (Microsoft recommended) |
| NTP server | `pool.ntp.org` | NTP server or pool for chrony |
| SSH hardening | *(ask y/n)* | Disable root login and password authentication |
| fail2ban whitelist | *(blank)* | Management IP/subnet to never ban (e.g. `192.168.1.0/24`) |

#### Security notes

- All passwords and credentials are entered interactively and never stored in the script itself.

#### Updating SQL Server

The installer is a **one-time provisioning** script — do not re-run it to patch an existing server. Updates are handled by apt:

- **OS security patches** apply automatically via the `unattended-upgrades` configuration the installer enables (Step 10). No reboot is taken automatically — schedule reboots yourself.
- **SQL Server cumulative updates** (`mssql-server`) are *not* applied automatically. Apply them deliberately during a maintenance window:

```bash
sudo apt-get update
sudo apt-get install --only-upgrade mssql-server mssql-tools18
systemctl status mssql-server
```

> SQL Server CUs stay within the installed major version (e.g. 2025). Back up your databases before applying, and confirm the new build with `SELECT @@VERSION` afterwards. Backups are handled by [sql-server-linux-backups](https://github.com/MarkLFT/sql-server-linux-backups).

### Migrate UFW to iptables (Existing SQL Server Hosts)

For servers already running SQL Server that were set up with UFW and need to switch to iptables.
UFW can be unstable on servers with complex NAT rules (such as the MSDTC port 135 PREROUTING redirect),
and iptables-persistent provides more predictable behaviour across reboots.

This script:

- Snapshots all current UFW rules and live iptables state to `/root/firewall-migration-<timestamp>/` before making any changes
- Parses open UFW ports and preserves them in the new iptables ruleset (so no ports are accidentally lost)
- Builds a clean iptables ruleset with INPUT DROP policy, allowing SSH, SQL Server (1433), and MSDTC ports
- Reads MSDTC port configuration from `/var/opt/mssql/mssql.conf` automatically (defaults to 13500/51999)
- Adds NAT PREROUTING and OUTPUT rules to redirect port 135 to the MSDTC RPC port
- Persists all rules via iptables-persistent and enables netfilter-persistent on boot
- Removes UFW completely

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/migrate-ufw-to-iptables.sh -o /tmp/migrate-ufw-to-iptables.sh && sudo bash /tmp/migrate-ufw-to-iptables.sh
```

To roll back if something goes wrong:

```bash
sudo iptables-restore < /root/firewall-migration-*/iptables-v4-before.rules
```
