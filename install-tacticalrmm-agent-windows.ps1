#Requires -RunAsAdministrator
# =============================================================================
# TacticalRMM Agent Installer — Windows
#
# Prompts for all sensitive values — safe for public hosting.
#
# Usage (run as Administrator):
#   Invoke-WebRequest https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-trmm-agent-windows.ps1 `
#     -OutFile "$env:TEMP\install-trmm-agent-windows.ps1"
#   & "$env:TEMP\install-trmm-agent-windows.ps1"
# =============================================================================

$ErrorActionPreference = "Stop"

# --- Colour helpers ----------------------------------------------------------
function Write-Header {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║        TacticalRMM Agent Installer                   ║" -ForegroundColor Cyan
    Write-Host "║        Windows                                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "▶ $Title" -ForegroundColor Cyan
    Write-Host ("─" * 54) -ForegroundColor Cyan
}

function Write-Ok   { param([string]$Msg) Write-Host "  ✔  $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "  ℹ  $Msg" -ForegroundColor Yellow }
function Write-Warn { param([string]$Msg) Write-Host "  ⚠  $Msg" -ForegroundColor Yellow }
function Invoke-Die { param([string]$Msg) Write-Host "`n  ✖  $Msg" -ForegroundColor Red; exit 1 }

# --- Prompt helpers ----------------------------------------------------------
function Read-Value {
    param([string]$Label, [string]$Default = "")
    if ($Default) {
        $input = Read-Host "  $Label [$Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
        return $input.Trim()
    } else {
        do { $input = Read-Host "  $Label" } while ([string]::IsNullOrWhiteSpace($input))
        return $input.Trim()
    }
}

function Read-Secret {
    param([string]$Label)
    do {
        $secure = Read-Host "  $Label" -AsSecureString
        $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if ([string]::IsNullOrWhiteSpace($plain)) {
            Write-Host "  Value cannot be empty." -ForegroundColor Red
        }
    } while ([string]::IsNullOrWhiteSpace($plain))
    return $plain
}

function Read-Confirm {
    param([string]$Question, [string]$Default = "y")
    $prompt = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
    $ans = Read-Host "  $Question $prompt"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
    return $ans.ToLower() -eq "y"
}

function Read-Choice {
    param([string]$Label, [string[]]$Options)
    Write-Host "  ${Label}:"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "    $($i+1)) $($Options[$i])"
    }
    do {
        $choice = Read-Host "  Choice [1-$($Options.Count)]"
    } while (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $Options.Count)
    return $Options[[int]$choice - 1]
}

function Pick-FromList {
    param([string]$Label, [array]$Items, [string]$NameProp, [string]$IdProp)
    if ($Items.Count -eq 0) { return $null }
    Write-Host "  ${Label}:"
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "    $($i+1)) $($Items[$i].$NameProp)"
    }
    do {
        $choice = Read-Host "  Choice [1-$($Items.Count)]"
    } while (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $Items.Count)
    return $Items[[int]$choice - 1]
}

# =============================================================================
# TRMM API HELPERS
# =============================================================================
# TacticalRMM REST API — no path prefix, endpoints are at the root.
# e.g. https://api.yourdomain.com/clients/
# Docs: https://docs.tacticalrmm.com/functions/api/

$TrmmUrl   = ""
$TrmmToken = ""

function Invoke-TrmmGet {
    param([string]$Endpoint)
    $headers = @{ "X-API-KEY" = $TrmmToken; "Content-Type" = "application/json" }
    return Invoke-RestMethod -Uri "$TrmmUrl/$Endpoint" -Headers $headers -Method Get
}

function Invoke-TrmmPost {
    param([string]$Endpoint, [hashtable]$Body)
    $headers = @{ "X-API-KEY" = $TrmmToken; "Content-Type" = "application/json" }
    return Invoke-RestMethod -Uri "$TrmmUrl/$Endpoint" -Headers $headers -Method Post `
        -Body ($Body | ConvertTo-Json -Depth 5) -ContentType "application/json"
}

# =============================================================================
# MAIN
# =============================================================================

Write-Header

# --- Connection --------------------------------------------------------------
Write-Section "TacticalRMM Connection"
$TrmmUrl = (Read-Value "TacticalRMM API URL (e.g. https://api.yourdomain.com)").TrimEnd('/')

Write-Host ""
Write-Host "  Generate an API key in TacticalRMM:" -ForegroundColor Yellow
Write-Host "  Settings → Global Settings → API Keys → Add API Key" -ForegroundColor Yellow
Write-Host ""
$TrmmToken = Read-Secret "API Key"

Write-Info "Testing connection..."
try {
    $headers = @{ "X-API-KEY" = $TrmmToken; "Content-Type" = "application/json" }
    $null = Invoke-RestMethod -Uri "$TrmmUrl/clients/" -Headers $headers -Method Get
    Write-Ok "Connected successfully"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 401 -or $code -eq 403) {
        Invoke-Die "Authentication failed (HTTP $code) — check your API key"
    } else {
        Invoke-Die "Could not reach TacticalRMM (HTTP $code) — check the URL"
    }
}

# --- Client ------------------------------------------------------------------
Write-Section "Client"
Write-Info "Loading clients..."
$Clients = Invoke-TrmmGet "clients/"
if ($Clients.Count -eq 0) { Invoke-Die "No clients found — create a client in TacticalRMM first" }

$SelectedClient = Pick-FromList "Select client" $Clients "name" "id"
Write-Ok "Client: $($SelectedClient.name) (ID: $($SelectedClient.id))"

# --- Site --------------------------------------------------------------------
Write-Section "Site"
Write-Info "Loading sites for $($SelectedClient.name)..."
$AllSites = Invoke-TrmmGet "sites/"
$Sites = @($AllSites | Where-Object { $_.client -eq $SelectedClient.id })
if ($Sites.Count -eq 0) { Invoke-Die "No sites found for $($SelectedClient.name) — create a site first" }

$SelectedSite = Pick-FromList "Select site" $Sites "name" "id"
Write-Ok "Site: $($SelectedSite.name) (ID: $($SelectedSite.id))"

# --- Agent type --------------------------------------------------------------
Write-Section "Agent"
Write-Host ""
$AgentType = (Read-Choice "Agent type" @("Server", "Workstation")).ToLower()
Write-Info "Type: $AgentType"

# --- Summary & confirm -------------------------------------------------------
Write-Section "Configuration Summary"
Write-Host ""
Write-Host "  Server:     $TrmmUrl"
Write-Host "  Client:     $($SelectedClient.name)"
Write-Host "  Site:       $($SelectedSite.name)"
Write-Host "  Agent type: $AgentType"
Write-Host ""

if (-not (Read-Confirm "Proceed with installation")) {
    Write-Host "Aborted."; exit 0
}

# =============================================================================
# GENERATE INSTALLER VIA DEPLOYMENT API
# =============================================================================

Write-Section "Generating Installer"

# Randomised temp path to prevent TOCTOU
$InstallerPath = Join-Path $env:TEMP ("trmm-" + [System.IO.Path]::GetRandomFileName() + ".exe")

# Try deployment API first
$DeployUrl = $null
try {
    Write-Info "Creating deployment token..."
    $deployBody = @{
        site         = $SelectedSite.id
        agent_type   = $AgentType
        expires      = $null
        install_flags = @{ rdp = $false; ping = $true; power = $false }
    }
    $deployResult = Invoke-TrmmPost "clients/$($SelectedClient.id)/deployments/" $deployBody
    $DeployUrl = $deployResult.url
} catch {
    Write-Warn "Deployment API not available — trying direct installer endpoint..."
}

if ($DeployUrl) {
    Write-Info "Downloading installer from deployment URL..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $DeployUrl -OutFile $InstallerPath -UseBasicParsing
    } catch {
        Invoke-Die "Failed to download installer: $_"
    }
} else {
    # Fall back to direct installer generation endpoint
    $Arch = if ([Environment]::Is64BitOperatingSystem) { "64" } else { "32" }
    $InstallerUrl = "$TrmmUrl/agents/installer/?client_id=$($SelectedClient.id)&site_id=$($SelectedSite.id)&agent_type=$AgentType&arch=$Arch&plat=windows&token=$TrmmToken"
    Write-Info "Downloading installer (arch: $Arch-bit)..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing
    } catch {
        Write-Host ""
        Write-Warn "Automatic installer generation is not available via the API."
        Write-Warn "Please generate an installer manually:"
        Write-Host ""
        Write-Host "    1. In TacticalRMM: Agents → Install Agent" -ForegroundColor Yellow
        Write-Host "    2. Select client: $($SelectedClient.name), site: $($SelectedSite.name)" -ForegroundColor Yellow
        Write-Host "    3. Select: Windows, $AgentType" -ForegroundColor Yellow
        Write-Host "    4. Download and run the generated installer" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

# Verify it's an executable (MZ header)
$magic = [System.IO.File]::ReadAllBytes($InstallerPath) | Select-Object -First 2
if (-not ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A)) {
    Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
    Invoke-Die "Downloaded file is not a valid executable — check API key permissions"
}
Write-Ok "Installer downloaded"

# Verify signature
Write-Info "Verifying digital signature..."
$sig = Get-AuthenticodeSignature -FilePath $InstallerPath
if ($sig.Status -ne "Valid") {
    Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
    Invoke-Die "Installer signature is invalid (status: $($sig.Status)) — aborting"
}
Write-Ok "Signature valid: $($sig.SignerCertificate.Subject)"

# =============================================================================
# INSTALL
# =============================================================================

Write-Section "Installing Agent"
Write-Info "Running installer silently..."

$proc = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -notin @(0, 3010)) {
    Invoke-Die "Installer exited with code $($proc.ExitCode)"
}

# --- Verify ------------------------------------------------------------------
Write-Section "Verifying"
Start-Sleep -Seconds 5

$svc = Get-Service -Name "tacticalrmm" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Ok "tacticalrmm service is running"
} else {
    $mesh = Get-Service -Name "Mesh Agent*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($mesh -and $mesh.Status -eq "Running") {
        Write-Ok "Mesh Agent service is running"
    } else {
        Write-Warn "Could not verify service — check Services or Event Viewer"
    }
}

# =============================================================================
# SUMMARY
# =============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║          TacticalRMM Agent Installed ✔               ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Client:  $($SelectedClient.name)"
Write-Host "  Site:    $($SelectedSite.name)"
Write-Host "  Type:    $AgentType"
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor White
Write-Host "  Status:   " -NoNewline; Write-Host "Get-Service tacticalrmm" -ForegroundColor Cyan
Write-Host "  Restart:  " -NoNewline; Write-Host "Restart-Service tacticalrmm" -ForegroundColor Cyan
Write-Host ""
Write-Host "  The agent should appear in TacticalRMM within a few seconds." -ForegroundColor Yellow
Write-Host ""
