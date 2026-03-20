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

### Zabbix Agent

Installs Zabbix Agent 2 on systems to be monitored. Configures it to connect to a local proxy.
Designed to be run from within TacticalRMM — obtains values from site and global variables.
Will auto-detect monitorable services (SQL Server, MySQL, PostgreSQL, Nginx, Apache, Docker, Redis) and write the appropriate plugin config stubs.
Sends a Discord notification on install or upgrade.

#### TacticalRMM Variables Required

| Variable         | Scope  | Example                                |
| ---------------- | ------ | -------------------------------------- |
| `ZabbixProxy`    | Site   | `10.10.1.5`                            |
| `ZabbixServer`   | Site   | `10.10.0.10`                           |
| `DiscordWebhook` | Global | `https://discord.com/api/webhooks/...` |
| `ZabbixVersion`  | Global | `7.4` (Linux) / `7.4.0` (Windows)      |

#### Linux Agent

Via TacticalRMM with site variables:

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux-tactical-rmm.sh | sudo bash -s -- "{{site.ZabbixProxy}}" "{{site.ZabbixServer}}" "{{global.DiscordWebhook}}" "{{global.ZabbixVersion}}"
```

Manual use with real values:

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux-tactical-rmm.sh | sudo bash -s -- "10.10.1.5" "10.10.0.10" "https://discord.com/api/webhooks/..." "7.4"
```

#### Windows Agent (Zabbix)

Via TacticalRMM (recommended):

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows-tactical-rmm.ps1))) -ZabbixProxy "{{site.ZabbixProxy}}" -ZabbixServer "{{site.ZabbixServer}}" -DiscordWebhook "{{global.DiscordWebhook}}" -ZabbixVersion "{{global.ZabbixVersion}}"
```

Manual use — download first then run:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows-tactical-rmm.ps1 -OutFile "$env:TEMP\install-zabbix-agent-windows-tactical-rmm.ps1"
& "$env:TEMP\install-zabbix-agent-windows-tactical-rmm.ps1" -ZabbixProxy "10.10.1.5" -ZabbixServer "10.10.0.10" -DiscordWebhook "https://discord.com/api/webhooks/..." -ZabbixVersion "7.4.0"
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

---

## TacticalRMM

### TacticalRMM Agent

Installs the TacticalRMM agent on a host and registers it with your TacticalRMM server.
Connects to the TacticalRMM API to fetch available clients and sites so you can pick from a list — no need to look up IDs manually.
Mesh URL and token are retrieved automatically from the API — no manual configuration of MeshCentral required.

**Prompts for:** TacticalRMM API URL, API key, client (list), site (list), agent type (Server/Workstation).

> **API Key:** Generate in TacticalRMM under Settings → Global Settings → API Keys → Add API Key.
> The key is entered interactively and never stored in the script.

#### Linux Agent (Ubuntu / Debian)

Installs both the **MeshCentral agent** (required for Take Control / Remote Background) and the **TacticalRMM agent** (monitoring, scripts, tasks, patch management).

The Linux agent is built from source using the community install script originally created by [netvolt](https://github.com/netvolt/LinuxRMM-Script) and maintained by [Nerdy-Technician](https://github.com/Nerdy-Technician/LinuxRMM-Script). This compiles the agent from the official [amidaware/rmmagent](https://github.com/amidaware/rmmagent) source code using Go. Compilation takes a few minutes on first run — this is normal.

> **Note:** This script targets the **community (free) licence**. The paid signed-agent installer from the TRMM UI is not required.
>
> **Auth Token (Linux only):** In TacticalRMM go to Agents → Install Agent → select Windows → Manual installation
> → click Show Manual Instructions → copy the value after `--auth`.
> This token is used to register the agent and can be reused for multiple installs until it expires.

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-tacticalrmm-agent-linux.sh \
  -o /tmp/install-tacticalrmm-agent-linux.sh && sudo bash /tmp/install-tacticalrmm-agent-linux.sh
```

After installation verify both services are running:

```bash
systemctl status tacticalagent
systemctl status meshagent
```

#### Windows Agent (TacticalRMM)

Uses the TacticalRMM deployment API to generate the installer automatically — no auth token needed.

Run as Administrator:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-tacticalrmm-agent-windows.ps1 -OutFile "$env:TEMP\install-tacticalrmm-agent-windows.ps1"
& "$env:TEMP\install-tacticalrmm-agent-windows.ps1"
```

---

## SQL Server

### SQL Server on Linux (Ubuntu 24.04) — Full Setup with Backup

End-to-end provisioning script for a dedicated SQL Server 2025 instance on Ubuntu 24.04 LTS.
Installs SQL Server, configures MSDTC, replaces UFW with iptables, sets up automated backups
using [Ola Hallengren's Maintenance Solution](https://github.com/olahallengren/sql-server-maintenance-solution),
and hardens the OS.

Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-sql-linux-with-backup.sh -o /tmp/install-sql-linux-with-backup.sh && sudo bash /tmp/install-sql-linux-with-backup.sh
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
| 7 | Installs Ola Hallengren's Maintenance Solution, creates a backup wrapper script, mounts a remote SMB share for backup copies, exports TDE certificates to a separate SMB share, and schedules a daily cron job |
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
| Local backup root | Same as backup directory | Root path for per-database backup subfolders |
| SMB share | *(none)* | Remote share for backup copies (`//server/share`) |
| SMB username | *(none)* | Credentials for the backup SMB share |
| SMB password | *(none)* | Credentials for the backup SMB share |
| SMB mount point | `/mnt/sqlbackups_remote` | Local mount point for the backup share |
| Backup retention | 30 days | How long to keep backups locally and remotely |
| TDE cert export password | *(none)* | Password to protect the exported TDE private key |
| TDE cert SMB share | *(none)* | Separate share for certificate storage (must differ from backup share) |
| TDE cert SMB username | *(none)* | Credentials for the certificate SMB share |
| TDE cert SMB password | *(none)* | Credentials for the certificate SMB share |
| TDE cert mount point | `/mnt/sqlcerts_remote` | Local mount point for the certificate share |
| NTP server | `pool.ntp.org` | NTP server or pool for chrony |
| SSH hardening | *(ask y/n)* | Disable root login and password authentication |
| fail2ban whitelist | *(blank)* | Management IP/subnet to never ban (e.g. `192.168.1.0/24`) |

#### Security notes

- All passwords and credentials are entered interactively and never stored in the script itself.
- SMB credentials are stored in root-only files (`chmod 600`) under `/root/`.
- TDE certificates are stored separately from backups — locally in `/etc/mssql-tde-certs/` (root-only) and on a dedicated SMB share distinct from the backup share.
- The TDE certificate export password must be stored offline (password manager or physical safe) — without it, backups cannot be restored on another server.
