# Scripts
Collection of Scripts for Regular Tasks

# Zabbix

## Zabbix Proxy
Install a Zabbix proxy onto a Debian host to act as a remote proxy to talk to a central Zabbix server.

### Lite Version
Fixed settings: Active mode, SQLite3 database, performance tuned for a small LAN (~12 agents).  
Prompts for: Zabbix version, proxy hostname, server address, and PSK encryption.
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy.sh -o /tmp/install-zabbix-proxy.sh && sudo bash /tmp/install-zabbix-proxy.sh
```

### Full Version
Prompts for all settings including proxy mode, database type (SQLite3/MySQL/PostgreSQL), and performance tuning.
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy-full.sh -o /tmp/install-zabbix-proxy-full.sh && sudo bash /tmp/install-zabbix-proxy-full.sh
```

## Zabbix Agent
Installs a Zabbix Agent 2 on systems to be monitored. Configures it to connect to a local proxy.  
Designed to be run from within TacticalRMM — obtains values from site and global variables.  
Will auto-detect monitorable services (SQL Server, MySQL, PostgreSQL, Nginx, Apache, Docker, Redis) and write the appropriate plugin config stubs.

### TacticalRMM Variables Required

| Variable | Scope | Example |
|---|---|---|
| `ZabbixProxy` | Site | `10.10.1.5` |
| `ZabbixServer` | Site | `10.10.0.10` |
| `DiscordWebhook` | Global | `https://discord.com/api/webhooks/...` |
| `ZabbixVersion` | Global | `7.4` (Linux) / `7.4.0` (Windows) |

### Linux Agent
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux.sh | sudo bash -s -- "{{site.ZabbixProxy}}" "{{site.ZabbixServer}}" "{{global.DiscordWebhook}}" "{{global.ZabbixVersion}}"
```
Manual use with real values:
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux.sh | sudo bash -s -- "10.10.1.5" "10.10.0.10" "https://discord.com/api/webhooks/..." "7.4"
```

### Windows Agent
Via TacticalRMM (recommended):
```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows.ps1))) -ZabbixProxy "{{site.ZabbixProxy}}" -ZabbixServer "{{site.ZabbixServer}}" -DiscordWebhook "{{global.DiscordWebhook}}" -ZabbixVersion "{{global.ZabbixVersion}}"
```
Manual use — download first then run:
```powershell
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows.ps1 -OutFile "$env:TEMP\install-zabbix-agent-windows.ps1"
& "$env:TEMP\install-zabbix-agent-windows.ps1" -ZabbixProxy "10.10.1.5" -ZabbixServer "10.10.0.10" -DiscordWebhook "https://discord.com/api/webhooks/..." -ZabbixVersion "7.4.0"
```

## Zabbix Discovery
Sets up automatic network discovery of devices that either have the Zabbix agent installed or have SNMP configured.  
Connects to the Zabbix API, fetches proxies and host groups, and creates the discovery rule and auto-add actions.

**Checks performed:** Zabbix agent (port 10050), SNMPv2c (port 161), SNMPv1 (port 161)  
**Prompts for:** Zabbix server URL, API credentials, proxy, IP range, scan interval, SNMP community string, host groups.  
**Templates** are not assigned automatically — apply them manually after discovery.

```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/setup-zabbix-discovery.sh \
  -o /tmp/setup-zabbix-discovery.sh && bash /tmp/setup-zabbix-discovery.sh
```

---

# TacticalRMM

## TacticalRMM Agent
Installs the TacticalRMM agent on a host and registers it with your TacticalRMM server.  
Connects to the TacticalRMM API to fetch available clients and sites so you can pick from a list — no need to look up IDs manually.

**Prompts for:** TacticalRMM API URL, API key, client (list), site (list), agent type (Server/Workstation).

> **API Key:** Generate in TacticalRMM under Settings → Global Settings → API Keys → Add API Key.  
> The key is entered interactively and never stored in the script.

### Linux Agent (Ubuntu / Debian)
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-trmm-agent-linux.sh \
  -o /tmp/install-trmm-agent-linux.sh && sudo bash /tmp/install-trmm-agent-linux.sh
```

### Windows Agent
Run as Administrator:
```powershell
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-trmm-agent-windows.ps1 -OutFile "$env:TEMP\install-trmm-agent-windows.ps1"
& "$env:TEMP\install-trmm-agent-windows.ps1"
```

