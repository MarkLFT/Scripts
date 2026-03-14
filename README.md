# Scripts
Collection os Scripts for Regular Tasks

# Zabbix

## Zabbix Proxy
Install a Zabbix proxy ont oa Debian host to act as remote proxy to talk to a central Zabbix server.

### Lite Version
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy.sh -o /tmp/install-zabbix-proxy.sh && sudo bash /tmp/install-zabbix-proxy.sh
```

### Full Version
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy-full.sh -o /tmp/install-zabbix-proxy-full.sh && sudo bash /tmp/install-zabbix-proxy-full.sh
```

## Zabix Agent
Installs a generic Zabbix agent on systems to be monitored. Will configure it to use a local proxy.  

Designed to be run from within TactcialRMM, it obtains values from the site, and global variables.

### Linux Agent
```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux.sh | sudo bash -s -- "{{site.ZabbixProxy}}" "{{site.ZabbixServer}}" "{{global.DiscordWebhook}}" "{{global.ZabbixVersion}}"
```

or

```
curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-linux.sh -o install-zabbix-agent-linux.sh
chmod +x install-zabbix-agent-linux.sh
sudo ./install-zabbix-agent-linux.sh "10.10.1.5" "10.10.0.10" "https://discord.com/api/webhooks/..." "7.4"
```

### Windows Agent
```
Invoke-RestMethod https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows.ps1 | Invoke-Expression
```

or

```
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows.ps1))) -ZabbixProxy "10.10.1.5" -ZabbixServer "10.10.0.10" -DiscordWebhook https://discord.com/api/webhooks/..." -ZabbixVersion "7.4.0"
```

or

```
Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-agent-windows.ps1 -OutFile install-zabbix-agent-windows.ps1
.\install-zabbix-agent-windows.ps1 -ZabbixProxy "10.10.1.5" -ZabbixServer "10.10.0.10" -DiscordWebhook "https://discord.com/api/webhooks/..." -ZabbixVersion "7.4.0"
```
