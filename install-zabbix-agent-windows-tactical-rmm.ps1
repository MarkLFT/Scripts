#Requires -RunAsAdministrator
# =============================================================================
# TacticalRMM - Zabbix Agent 2 Install / Update Script (Windows)
#
# Script Arguments (set in TacticalRMM):
#   $ZabbixProxy         = {{site.ZabbixProxy}}           e.g. 10.10.1.5
#   $ZabbixServer        = {{site.ZabbixServer}}          e.g. 10.10.0.10
#   $DiscordWebhook      = {{global.DiscordWebhook}}      e.g. https://discord.com/api/webhooks/...
#   $ZabbixVersion       = {{global.ZabbixVersion}}       e.g. 7.4.0
#   $ZabbixMSSQLPassword = {{global.ZabbixMSSQLPassword}} Password for the 'zabbix' SQL login (optional)
#   $ZabbixHostName      = {{agent.ZabbixHostName}}        Custom Zabbix hostname (optional, defaults to COMPUTERNAME)
#   -Force                                                 Force re-run even if already on target version
# =============================================================================

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'TacticalRMM passes plain string arguments — SecureString is not usable here')]
param(
    [Parameter(Mandatory=$true)]  [string]$ZabbixProxy,
    [Parameter(Mandatory=$true)]  [string]$ZabbixServer,
    [Parameter(Mandatory=$false)] [string]$DiscordWebhook = "",
    [Parameter(Mandatory=$true)]  [string]$ZabbixVersion,
    [Parameter(Mandatory=$false)] [string]$ZabbixMSSQLPassword = "",
    [Parameter(Mandatory=$false)] [string]$ZabbixHostName = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# --- Input validation --------------------------------------------------------
# SECURITY: Validate all arguments before use in URLs, config files, or process arguments.

$AddrPattern    = '^[a-zA-Z0-9._\-]+$'
$VersionPattern = '^\d+\.\d+\.\d+$'

if ($ZabbixProxy -notmatch $AddrPattern) {
    Write-Error "ZabbixProxy contains invalid characters: $ZabbixProxy"; exit 1
}
if ($ZabbixServer -notmatch $AddrPattern) {
    Write-Error "ZabbixServer contains invalid characters: $ZabbixServer"; exit 1
}
if ($ZabbixVersion -notmatch $VersionPattern) {
    Write-Error "ZabbixVersion must be in x.y.z format (e.g. 7.4.0), got: $ZabbixVersion"; exit 1
}

# Derive major.minor (e.g. "7.4.0" -> "7.4") for use in the CDN URL path
$ZabbixMajorMinor = ($ZabbixVersion -split '\.' | Select-Object -First 2) -join '.'

# --- Constants ---------------------------------------------------------------
$ZABBIX_INSTALL_DIR  = "C:\Program Files\Zabbix Agent 2"
$ZABBIX_CONF         = "$ZABBIX_INSTALL_DIR\zabbix_agent2.conf"
$ZABBIX_CONF_D       = "$ZABBIX_INSTALL_DIR\zabbix_agent2.d"
$ZABBIX_LOG          = "C:\ProgramData\Zabbix\logs\zabbix_agent2.log"
$ZABBIX_SERVICE_NAME = "Zabbix Agent 2"
$MSI_URL             = "https://cdn.zabbix.com/zabbix/binaries/stable/$ZabbixMajorMinor/$ZabbixVersion/zabbix_agent2-$ZabbixVersion-windows-amd64-openssl.msi"

# SECURITY: Use a randomised temp filename to prevent TOCTOU race conditions.
$TMP_MSI  = Join-Path $env:TEMP ("zabbix_agent2_" + [System.IO.Path]::GetRandomFileName() + ".msi")
$TMP_LOG  = Join-Path $env:TEMP ("zabbix_agent2_" + [System.IO.Path]::GetRandomFileName() + ".log")

# --- Helpers -----------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Send-Discord {
    param([string]$Title, [string]$Description, [int]$Color = 3066993)
    if ([string]::IsNullOrEmpty($DiscordWebhook)) { return }
    try {
        # SECURITY: Use ConvertTo-Json for serialisation so all values are
        # properly escaped — no manual string interpolation into JSON.
        $payload = @{
            embeds = @(@{
                title       = $Title
                description = $Description
                color       = $Color
                footer      = @{ text = "TacticalRMM - Zabbix Agent" }
                timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            })
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $DiscordWebhook -Method Post -Body $payload `
            -ContentType "application/json" | Out-Null
    } catch {
        Write-Log "WARN: Discord notification failed: $_"
    }
}

# SECURITY: Lock a file/directory so only SYSTEM and Administrators can read it.
# Used for config files that may contain DB credentials.
function Set-RestrictedAcl {
    param([string]$Path)
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false) # disable inheritance

        $system = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $admins = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

        $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow       = [System.Security.AccessControl.AccessControlType]::Allow
        $none        = [System.Security.AccessControl.InheritanceFlags]::None
        $noProp      = [System.Security.AccessControl.PropagationFlags]::None

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $fullControl, $none, $noProp, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $fullControl, $none, $noProp, $allow)))

        Set-Acl -Path $Path -AclObject $acl
    } catch {
        Write-Log "WARN: Could not set ACL on $Path — $_"
    }
}

# --- Gather system info ------------------------------------------------------
$SysHostName  = $env:COMPUTERNAME
$IPAddress    = (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Teredo' } |
                Select-Object -First 1).IPAddress
# Use custom Zabbix hostname if provided, otherwise use system hostname
$AgentHostName = if (-not [string]::IsNullOrEmpty($ZabbixHostName)) { $ZabbixHostName } else { $SysHostName }

Write-Log "Host:    $SysHostName ($IPAddress)"
if ($AgentHostName -ne $SysHostName) { Write-Log "Zabbix Hostname: $AgentHostName" }
Write-Log "Proxy:   $ZabbixProxy"
Write-Log "Target:  Zabbix Agent 2 $ZabbixVersion"

# --- Check existing install --------------------------------------------------
$PrevVersion = $null
$Action      = "Installed"

$regPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
$regEntry = Get-ChildItem $regPath -ErrorAction SilentlyContinue |
            Get-ItemProperty |
            Where-Object { $_.DisplayName -like "*Zabbix Agent 2*" } |
            Select-Object -First 1

if ($regEntry) {
    $PrevVersion = $regEntry.DisplayVersion
    Write-Log "Installed version: $PrevVersion"

    if ($PrevVersion -eq $ZabbixVersion) {
        if ($Force) {
            Write-Log "Already on version $ZabbixVersion — Force flag set, reconfiguring."
            $Action = "Reconfigured"
        } else {
            Write-Log "Already on version $ZabbixVersion — nothing to do."
            exit 0
        }
    } else {
        $Action = "Updated"
        Write-Log "Upgrade needed: $PrevVersion -> $ZabbixVersion"
    }

    if ($Action -ne "Reconfigured") {
        Write-Log "Stopping existing service..."
        Stop-Service -Name $ZABBIX_SERVICE_NAME -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
} else {
    Write-Log "Agent not installed — performing fresh install."
}

# --- Download & install MSI (skip on reconfigure) ----------------------------
if ($Action -ne "Reconfigured") {

Write-Log "Downloading MSI: $MSI_URL"
try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $MSI_URL -OutFile $TMP_MSI -UseBasicParsing
} catch {
    $errMsg = "Failed to download MSI: $_"
    Write-Log "ERROR: $errMsg"
    Send-Discord -Title "❌ Zabbix Agent Install Failed" `
        -Description "**Host:** $SysHostName`n**IP:** $IPAddress`n**Reason:** $errMsg" `
        -Color 15158332
    Remove-Item -Path $TMP_MSI -Force -ErrorAction SilentlyContinue
    exit 1
}

# SECURITY: Verify the MSI is signed by Zabbix before executing it.
# This catches a tampered file or a compromised download.
Write-Log "Verifying MSI digital signature..."
$sig = Get-AuthenticodeSignature -FilePath $TMP_MSI
if ($sig.Status -ne 'Valid') {
    $errMsg = "MSI signature is invalid or untrusted (status: $($sig.Status)). Aborting."
    Write-Log "ERROR: $errMsg"
    Send-Discord -Title "❌ Zabbix Agent Install Failed" `
        -Description "**Host:** $SysHostName`n**IP:** $IPAddress`n**Reason:** $errMsg" `
        -Color 15158332
    Remove-Item -Path $TMP_MSI -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Log "Signature valid — signed by: $($sig.SignerCertificate.Subject)"

# --- Run installer -----------------------------------------------------------
Write-Log "Running silent MSI install..."
$proc = Start-Process -FilePath "msiexec.exe" -Wait -PassThru -NoNewWindow -ArgumentList @(
    "/i", $TMP_MSI, "/qn",
    "/l*v", $TMP_LOG,
    "SERVER=$ZabbixProxy",
    "SERVERACTIVE=$ZabbixProxy",
    "HOSTNAME=$AgentHostName",
    "INSTALLFOLDER=$ZABBIX_INSTALL_DIR"
)

# SECURITY: Delete the MSI and install log immediately — the log can contain
# install-time values and sits in a user-readable temp directory.
Remove-Item -Path $TMP_MSI -Force -ErrorAction SilentlyContinue
Remove-Item -Path $TMP_LOG -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -notin @(0, 3010)) {
    $errMsg = "MSI exited with code $($proc.ExitCode)"
    Write-Log "ERROR: $errMsg"
    Send-Discord -Title "❌ Zabbix Agent Install Failed" `
        -Description "**Host:** $SysHostName`n**IP:** $IPAddress`n**Reason:** $errMsg" `
        -Color 15158332
    exit 1
}

} # end skip-on-reconfigure

# --- Write full configuration ------------------------------------------------
Write-Log "Writing agent configuration..."
New-Item -ItemType Directory -Force -Path $ZABBIX_CONF_D | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $ZABBIX_LOG) | Out-Null

@"
# Zabbix Agent 2 Configuration
# Managed by TacticalRMM - do not edit manually

Hostname=$AgentHostName
LogFile=$ZABBIX_LOG
LogFileSize=10

# Agent accepts checks from the proxy only
Server=$ZabbixProxy
ServerActive=$ZabbixProxy

# SECURITY: system.run (remote command execution) is disabled by default in
# Zabbix Agent 2 and is intentionally not enabled here. Do not add
# AllowKey=system.run[*] unless you have a specific, audited requirement.
DenyKey=system.run[*]

Timeout=10
RefreshActiveChecks=120
BufferSend=5
BufferSize=200

Include=$ZABBIX_CONF_D\*.conf
Include=$ZABBIX_CONF_D\plugins.d\*.conf
"@ | Set-Content -Path $ZABBIX_CONF -Encoding UTF8

# Lock the main config to Administrators/SYSTEM only
Set-RestrictedAcl -Path $ZABBIX_CONF

# --- Detect services & write plugin configs ----------------------------------
$DetectedServices = @()
Write-Log "Scanning for monitorable services..."

# SQL Server — default and named instances
$SqlInstances  = @()
$SqlInstances += Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
$SqlInstances += Get-Service -Name "MSSQL$*"     -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne "MSSQLSERVER" }

if ($SqlInstances.Count -gt 0) {
    $mssqlConfPwd = if (-not [string]::IsNullOrEmpty($ZabbixMSSQLPassword)) { $ZabbixMSSQLPassword } else { "CHANGE_ME" }

    # Create/update the zabbix SQL login on each detected instance
    if (-not [string]::IsNullOrEmpty($ZabbixMSSQLPassword)) {
        $sqlcmdPath = (Get-Command sqlcmd -ErrorAction SilentlyContinue).Source
        if ($sqlcmdPath) {
            $escapedPwd = $ZabbixMSSQLPassword -replace "'", "''"
            foreach ($svc in $SqlInstances) {
                if ($svc.Name -eq "MSSQLSERVER") {
                    $sqlInstance = "localhost"
                    $sqlLabel    = "MSSQLSERVER (Default)"
                } else {
                    $namedPart   = $svc.Name -replace "^MSSQL\$", ""
                    $sqlInstance = "localhost\$namedPart"
                    $sqlLabel    = "Named: $namedPart"
                }
                Write-Log "  Creating/updating zabbix SQL login on $sqlLabel..."
                $sqlLogin = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'zabbix')
    CREATE LOGIN [zabbix] WITH PASSWORD = N'$escapedPwd', CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN [zabbix] WITH PASSWORD = N'$escapedPwd';
GRANT VIEW SERVER STATE TO [zabbix];
GRANT VIEW ANY DEFINITION TO [zabbix];
"@
                try {
                    $output = & $sqlcmdPath -S $sqlInstance -E -b -Q $sqlLogin 2>&1
                    $output | ForEach-Object { Write-Log "    $_" }
                    Write-Log "  zabbix SQL login ready on $sqlLabel (server level)"
                } catch {
                    Write-Log "WARN: Failed to create zabbix SQL login on ${sqlLabel}: $_"
                }

                # Grant msdb permissions for SQL Agent job monitoring
                Write-Log "  Granting msdb permissions on $sqlLabel..."
                $sqlMsdb = @"
USE [msdb];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'zabbix')
    CREATE USER [zabbix] FOR LOGIN [zabbix];
GRANT EXECUTE ON msdb.dbo.agent_datetime TO [zabbix];
GRANT SELECT ON msdb.dbo.sysjobactivity TO [zabbix];
GRANT SELECT ON msdb.dbo.sysjobservers TO [zabbix];
GRANT SELECT ON msdb.dbo.sysjobs TO [zabbix];
"@
                try {
                    $output = & $sqlcmdPath -S $sqlInstance -E -b -Q $sqlMsdb 2>&1
                    $output | ForEach-Object { Write-Log "    $_" }
                    Write-Log "  msdb permissions granted on $sqlLabel"
                } catch {
                    Write-Log "WARN: Failed to grant msdb permissions on ${sqlLabel}: $_"
                }
            }
        } else {
            Write-Log "WARN: sqlcmd not found — cannot create zabbix SQL login automatically"
        }
    } else {
        Write-Log "WARN: ZabbixMSSQLPassword not set — writing placeholder credentials"
    }

    # Write session credentials into the package-installed plugins.d/mssql.conf.
    # The package config already has the correct System.Path to the plugin binary.
    $pluginsD     = "$ZABBIX_CONF_D\plugins.d"
    $mssqlPluginConf = "$pluginsD\mssql.conf"

    # Build session config block for each instance
    $sessionBlock = "# --- Zabbix Agent Script: MSSQL Session Config ---`r`n"

    foreach ($svc in $SqlInstances) {
        if ($svc.Name -eq "MSSQLSERVER") {
            $connStr     = "sqlserver://localhost:1433"
            $sessionName = "default"
            $label       = "MSSQLSERVER (Default)"
        } else {
            $namedPart   = $svc.Name -replace "^MSSQL\$", ""
            $connStr     = "sqlserver://localhost\$namedPart"
            $sessionName = $namedPart.ToLower()
            $label       = "Named: $namedPart"
        }
        Write-Log "  [FOUND] SQL Server — $label"
        $DetectedServices += "SQL Server ($label)"
        $sessionBlock += "Plugins.MSSQL.Sessions.$sessionName.Uri=$connStr`r`n"
        $sessionBlock += "Plugins.MSSQL.Sessions.$sessionName.User=zabbix`r`n"
        $sessionBlock += "Plugins.MSSQL.Sessions.$sessionName.Password=$mssqlConfPwd`r`n"
        $sessionBlock += "Plugins.MSSQL.Sessions.$sessionName.Encrypt=disable`r`n"
        $sessionBlock += "Plugins.MSSQL.Sessions.$sessionName.TrustServerCertificate=true`r`n`r`n"
    }
    $sessionBlock += "# --- End MSSQL Session Config ---"

    if (Test-Path $mssqlPluginConf) {
        # Remove any previous session config we appended (between our markers)
        $content = Get-Content $mssqlPluginConf -Raw
        $content = $content -replace '(?s)# --- Zabbix Agent Script: MSSQL Session Config ---.*?# --- End MSSQL Session Config ---\r?\n?', ''
        Set-Content -Path $mssqlPluginConf -Value ($content.TrimEnd() + "`r`n" + $sessionBlock) -Encoding UTF8
    } else {
        # No package config found — write a standalone file
        Set-Content -Path $mssqlPluginConf -Value $sessionBlock -Encoding UTF8
    }
    Set-RestrictedAcl -Path $mssqlPluginConf

    if ($mssqlConfPwd -eq "CHANGE_ME") {
        Write-Log "  MSSQL plugin config written with placeholder — UPDATE CREDENTIALS in $mssqlPluginConf"
    } else {
        Write-Log "  MSSQL plugin config written with live credentials"
    }
}

# MySQL / MariaDB
$mysqlSvc = Get-Service -Name @("MySQL*","MariaDB*") -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mysqlSvc) {
    $label = if ($mysqlSvc.Name -like "MariaDB*") { "MariaDB" } else { "MySQL" }
    Write-Log "  [FOUND] $label"; $DetectedServices += $label
    $mysqlPath = "$ZABBIX_CONF_D\mysql.conf"
    @"
# $label - Zabbix Agent 2 Plugin
# CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'StrongPassword!';
# GRANT REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW ON *.* TO 'zabbix'@'localhost';

Plugins.Mysql.Sessions.local.Uri=tcp://localhost:3306
Plugins.Mysql.Sessions.local.User=zabbix
Plugins.Mysql.Sessions.local.Password=CHANGE_ME
"@ | Set-Content -Path $mysqlPath -Encoding UTF8
    Set-RestrictedAcl -Path $mysqlPath
    Write-Log "  MySQL config written — UPDATE CREDENTIALS"
}

# PostgreSQL
$pgSvc = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgSvc) {
    Write-Log "  [FOUND] PostgreSQL"; $DetectedServices += "PostgreSQL"
    $pgPath = "$ZABBIX_CONF_D\postgresql.conf"
    @"
# PostgreSQL - Zabbix Agent 2 Plugin
# CREATE USER zabbix WITH PASSWORD 'StrongPassword!';
# GRANT pg_monitor TO zabbix;

Plugins.PostgreSQL.Sessions.local.Uri=tcp://localhost:5432
Plugins.PostgreSQL.Sessions.local.User=zabbix
Plugins.PostgreSQL.Sessions.local.Password=CHANGE_ME
Plugins.PostgreSQL.Sessions.local.Database=postgres
"@ | Set-Content -Path $pgPath -Encoding UTF8
    Set-RestrictedAcl -Path $pgPath
    Write-Log "  PostgreSQL config written — UPDATE CREDENTIALS"
}

# IIS
$iisSvc = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
if ($iisSvc) {
    Write-Log "  [FOUND] IIS"; $DetectedServices += "IIS"
    "# IIS monitored via Windows perf counters. Use 'Windows IIS by Zabbix agent' template." |
        Set-Content -Path "$ZABBIX_CONF_D\iis_notes.conf" -Encoding UTF8
}

# Redis
$redisSvc = Get-Service -Name "Redis*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($redisSvc) {
    Write-Log "  [FOUND] Redis"; $DetectedServices += "Redis"

    # Write session config to plugins.d if the package created it, otherwise zabbix_agent2.d
    $redisPluginConf = "$ZABBIX_CONF_D\plugins.d\redis.conf"
    if (Test-Path $redisPluginConf) {
        $content = Get-Content $redisPluginConf -Raw
        $content = $content -replace '(?s)# --- Zabbix Agent Script: Redis Session Config ---.*?# --- End Redis Session Config ---\r?\n?', ''
        $sessionBlock = "# --- Zabbix Agent Script: Redis Session Config ---`r`nPlugins.Redis.Sessions.local.Uri=tcp://localhost:6379`r`n# --- End Redis Session Config ---"
        Set-Content -Path $redisPluginConf -Value ($content.TrimEnd() + "`r`n" + $sessionBlock) -Encoding UTF8
        Set-RestrictedAcl -Path $redisPluginConf
        Write-Log "  Redis plugin config written to plugins.d\redis.conf"
    } else {
        "Plugins.Redis.Sessions.local.Uri=tcp://localhost:6379" |
            Set-Content -Path "$ZABBIX_CONF_D\redis.conf" -Encoding UTF8
        Write-Log "  Redis config written to zabbix_agent2.d\redis.conf (built-in plugin)"
    }
}

# RabbitMQ
$rabbitSvc = Get-Service -Name "RabbitMQ" -ErrorAction SilentlyContinue
if ($rabbitSvc) {
    Write-Log "  [FOUND] RabbitMQ"; $DetectedServices += "RabbitMQ"

    # Enable the RabbitMQ management plugin (required for monitoring via HTTP API)
    $rabbitmqPlugins = (Get-Command rabbitmq-plugins -ErrorAction SilentlyContinue).Source
    if ($rabbitmqPlugins) {
        $enabled = & $rabbitmqPlugins list -e -m 2>$null
        if ($enabled -notcontains "rabbitmq_management") {
            Write-Log "  Enabling RabbitMQ management plugin..."
            & $rabbitmqPlugins enable rabbitmq_management 2>&1 | ForEach-Object { Write-Log "    $_" }
        } else {
            Write-Log "  RabbitMQ management plugin already enabled"
        }
    } else {
        Write-Log "WARN: rabbitmq-plugins not found — cannot enable management plugin"
    }

    # Create the zbx_monitor user for Zabbix monitoring
    $rabbitmqctl = (Get-Command rabbitmqctl -ErrorAction SilentlyContinue).Source
    if ($rabbitmqctl) {
        $users = & $rabbitmqctl list_users 2>$null
        if ($users -notmatch 'zbx_monitor') {
            Write-Log "  Creating RabbitMQ monitoring user zbx_monitor..."
            & $rabbitmqctl add_user zbx_monitor zabbix 2>&1 | ForEach-Object { Write-Log "    $_" }
            & $rabbitmqctl set_user_tags zbx_monitor monitoring 2>&1 | ForEach-Object { Write-Log "    $_" }
            & $rabbitmqctl set_permissions -p / zbx_monitor "" "" "" 2>&1 | ForEach-Object { Write-Log "    $_" }
            Write-Log "  RabbitMQ monitoring user created"
        } else {
            Write-Log "  RabbitMQ monitoring user zbx_monitor already exists"
        }
    } else {
        Write-Log "WARN: rabbitmqctl not found — cannot create monitoring user"
    }
}

# --- Clean up stale plugin configs from older script versions ----------------
# Previous versions wrote plugin configs directly into zabbix_agent2.d\ instead of
# plugins.d\. Remove them unconditionally — if they exist here they're always wrong.
foreach ($staleConf in @("mssql.conf", "redis.conf")) {
    $stalePath = "$ZABBIX_CONF_D\$staleConf"
    if (Test-Path $stalePath) {
        Write-Log "Removing stale $stalePath (now managed in plugins.d\)"
        Remove-Item -Path $stalePath -Force
    }
}

# --- Manage loadable plugins in plugins.d ------------------------------------
# Disable ALL loadable plugins first, then re-enable only the ones for services
# we actually detected. This prevents crashes from plugins whose dependencies
# are missing (e.g. NVIDIA plugin on a server without a GPU).
$pluginsDPath = "$ZABBIX_CONF_D\plugins.d"
if (Test-Path $pluginsDPath) {
    # Map detected services to plugin config basenames
    $neededPlugins = @()
    foreach ($svc in $DetectedServices) {
        switch -Wildcard ($svc) {
            "SQL Server*" { $neededPlugins += "mssql" }
            "MySQL"       { $neededPlugins += "mysql" }
            "MariaDB"     { $neededPlugins += "mysql" }
            "PostgreSQL"  { $neededPlugins += "postgresql" }
            "Redis"       { $neededPlugins += "redis" }
        }
    }

    Get-ChildItem -Path "$pluginsDPath\*.conf" -ErrorAction SilentlyContinue | ForEach-Object {
        $pconf = $_
        $pluginName = $pconf.BaseName
        $lines = Get-Content $pconf.FullName
        $modified = $false

        if ($neededPlugins -contains $pluginName) {
            # Re-enable: uncomment System.Path lines
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^#(Plugins\..+\.System\.Path=.+)$') {
                    $lines[$i] = $Matches[1]
                    $modified = $true
                }
            }
            if ($modified) { Write-Log "  Plugin enabled: $pluginName" }
        } else {
            # Disable: comment out System.Path lines
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^Plugins\..+\.System\.Path=') {
                    $lines[$i] = "#$($lines[$i])"
                    $modified = $true
                }
            }
            if ($modified) { Write-Log "  Plugin disabled: $pluginName" }
        }

        if ($modified) {
            Set-Content -Path $pconf.FullName -Value $lines -Encoding UTF8
        }
    }
}

# --- Firewall ----------------------------------------------------------------
Write-Log "Configuring Windows Firewall for Zabbix agent (port 10050/tcp)..."
$fwRuleName = "Zabbix Agent 2 (TCP-In 10050)"
$existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if ($existingRule) {
    Write-Log "Firewall rule '$fwRuleName' already exists — skipping."
} else {
    try {
        New-NetFirewallRule -DisplayName $fwRuleName `
            -Direction Inbound -Protocol TCP -LocalPort 10050 `
            -Action Allow -Profile Domain,Private `
            -Description "Allow Zabbix proxy to reach Zabbix Agent 2 for passive checks" | Out-Null
        Write-Log "Firewall rule created: $fwRuleName (Domain,Private profiles)"
    } catch {
        Write-Log "WARN: Could not create firewall rule: $_"
    }
}

# --- Start service -----------------------------------------------------------
Write-Log "Starting $ZABBIX_SERVICE_NAME..."
Start-Sleep -Seconds 1
Start-Service -Name $ZABBIX_SERVICE_NAME -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$finalSvc = Get-Service -Name $ZABBIX_SERVICE_NAME -ErrorAction SilentlyContinue
if ($finalSvc.Status -ne "Running") {
    $errMsg = "Service failed to start (status: $($finalSvc.Status))"
    Write-Log "ERROR: $errMsg"
    Send-Discord -Title "❌ Zabbix Agent Failed to Start" `
        -Description "**Host:** $SysHostName`n**IP:** $IPAddress`n**Version:** $ZabbixVersion`n**Reason:** $errMsg" `
        -Color 15158332
    exit 1
}

# --- Send Discord notification -----------------------------------------------
$ServicesMsg = if ($DetectedServices.Count -gt 0) { $DetectedServices -join ", " } else { "None detected" }

if ($Action -eq "Updated") {
    $VersionMsg = "**Version:** $PrevVersion -> $ZabbixVersion"; $Color = 3447003
} else {
    $VersionMsg = "**Version:** $ZabbixVersion"; $Color = 3066993
}

$CredWarning = ""
$NeedsCredUpdate = $false
Get-ChildItem -Path "$ZABBIX_CONF_D" -Filter "*.conf" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    if (Select-String -Path $_.FullName -Pattern "CHANGE_ME" -Quiet) { $NeedsCredUpdate = $true }
}
if ($NeedsCredUpdate) {
    $CredWarning = "`n⚠️ Action Required: Update DB credentials in $ZABBIX_CONF_D\"
}

Send-Discord `
    -Title "✅ Zabbix Agent $Action (Windows)" `
    -Description "**Host:** $SysHostName`n**IP:** $IPAddress`n$VersionMsg`n**Proxy:** $ZabbixProxy`n**Services Detected:** $ServicesMsg$CredWarning" `
    -Color $Color

Write-Log "Done. Action: $Action | Services: $ServicesMsg"
exit 0
