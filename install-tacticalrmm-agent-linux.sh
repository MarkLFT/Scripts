#!/usr/bin/env bash
# =============================================================================
# TacticalRMM Agent Installer — Linux (Ubuntu / Debian)
#
# Prompts for all sensitive values — safe for public hosting.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-trmm-agent-linux.sh \
#     -o /tmp/install-trmm-agent-linux.sh && sudo bash /tmp/install-trmm-agent-linux.sh
# =============================================================================

set -uo pipefail

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        TacticalRMM Agent Installer                   ║${RESET}"
    echo -e "${CYAN}${BOLD}║        Linux — Ubuntu / Debian                       ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}${BOLD}▶ $1${RESET}"
    echo -e "${CYAN}$(printf '─%.0s' {1..54})${RESET}"
}

log_ok()    { echo -e "  ${GREEN}✔${RESET}  $1"; }
log_info()  { echo -e "  ${YELLOW}ℹ${RESET}  $1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
die()       { echo -e "\n  ${RED}✖  $1${RESET}" >&2; exit 1; }

# --- Must run as root --------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash install-trmm-agent-linux.sh"

# --- OS check ----------------------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS"
. /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] \
    || die "Unsupported OS: $ID (Ubuntu and Debian only)"

# --- Dependencies ------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    log_info "Installing jq..."
    apt-get install -y -q jq >/dev/null 2>&1 || die "Could not install jq"
fi

# =============================================================================
# PROMPT HELPERS
# =============================================================================

prompt_value() {
    local label="$1" default="$2"
    REPLY=""
    if [[ -n "$default" ]]; then
        read -rp "  ${label} [${default}]: " REPLY
        [[ -z "$REPLY" ]] && REPLY="$default"
    else
        while [[ -z "$REPLY" ]]; do
            read -rp "  ${label}: " REPLY
        done
    fi
}

prompt_secret() {
    local label="$1"
    SECRET_REPLY=""
    while [[ -z "$SECRET_REPLY" ]]; do
        read -rsp "  ${label}: " SECRET_REPLY
        echo ""
        [[ -z "$SECRET_REPLY" ]] && echo -e "  ${RED}Value cannot be empty.${RESET}"
    done
}

prompt_confirm() {
    local question="$1" default="${2:-y}"
    local prompt; [[ "$default" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
    read -rp "  ${question} ${prompt}: " ans
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" ]]
}

prompt_choice() {
    local label="$1"; shift
    local options=("$@")
    echo "  ${label}:"
    for i in "${!options[@]}"; do
        echo "    $((i+1))) ${options[$i]}"
    done
    local choice
    while true; do
        read -rp "  Choice [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            REPLY="${options[$((choice-1))]}"; return 0
        fi
        echo -e "  ${RED}Invalid choice.${RESET}"
    done
}

pick_from_list() {
    local label="$1" json="$2" name_field="$3" id_field="$4"
    local count
    count=$(echo "$json" | jq 'length')
    [[ "$count" -eq 0 ]] && { REPLY=""; REPLY_ID=""; return 1; }
    echo "  ${label}:"
    local i=1
    while IFS= read -r name; do
        echo "    ${i}) ${name}"
        ((i++))
    done < <(echo "$json" | jq -r ".[] | ${name_field}")
    local choice
    while true; do
        read -rp "  Choice [1-${count}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            REPLY=$(echo    "$json" | jq -r ".[$(( choice - 1 ))] | ${name_field}")
            REPLY_ID=$(echo "$json" | jq -r ".[$(( choice - 1 ))] | ${id_field}")
            return 0
        fi
        echo -e "  ${RED}Invalid choice.${RESET}"
    done
}

# =============================================================================
# TRMM API HELPERS
# =============================================================================

TRMM_URL=""
TRMM_TOKEN=""

trmm_api() {
    local endpoint="$1"
    curl -s -X GET "${TRMM_URL}/api/v3/${endpoint}" \
        -H "Content-Type: application/json" \
        -H "X-API-KEY: ${TRMM_TOKEN}" \
        2>/dev/null
}

# =============================================================================
# COLLECT CONFIGURATION
# =============================================================================

print_header

# --- TRMM connection ---------------------------------------------------------
print_section "TacticalRMM Connection"
REPLY=""
prompt_value "TacticalRMM API URL (e.g. https://api.yourdomain.com)" ""
TRMM_URL="${REPLY%/}"

echo ""
echo -e "  ${YELLOW}Generate an API key in TacticalRMM:${RESET}"
echo -e "  Settings → Global Settings → API Keys → Add API Key"
echo ""
SECRET_REPLY=""
prompt_secret "API Key"
TRMM_TOKEN="$SECRET_REPLY"

# Verify connection
log_info "Testing connection..."
PING_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-KEY: ${TRMM_TOKEN}" \
    "${TRMM_URL}/api/v3/clients/" 2>/dev/null)

if [[ "$PING_RESULT" == "200" ]]; then
    log_ok "Connected successfully"
elif [[ "$PING_RESULT" == "401" ]]; then
    die "Authentication failed — check your API key"
else
    die "Could not reach TacticalRMM (HTTP $PING_RESULT) — check the URL"
fi

# --- Select client -----------------------------------------------------------
print_section "Client"
log_info "Loading clients..."
CLIENTS_JSON=$(trmm_api "clients/")
CLIENT_COUNT=$(echo "$CLIENTS_JSON" | jq 'length' 2>/dev/null || echo "0")
[[ "$CLIENT_COUNT" -eq 0 ]] && die "No clients found — create a client in TacticalRMM first"

pick_from_list "Select client" "$CLIENTS_JSON" ".name" ".id" \
    || die "No clients available"
CLIENT_NAME="$REPLY"
CLIENT_ID="$REPLY_ID"
log_ok "Client: $CLIENT_NAME (ID: $CLIENT_ID)"

# --- Select site -------------------------------------------------------------
print_section "Site"
log_info "Loading sites for $CLIENT_NAME..."
SITES_JSON=$(trmm_api "sites/")
# Filter to just this client's sites
SITES_JSON=$(echo "$SITES_JSON" | jq "[.[] | select(.client == ${CLIENT_ID})]")
SITE_COUNT=$(echo "$SITES_JSON" | jq 'length')
[[ "$SITE_COUNT" -eq 0 ]] && die "No sites found for $CLIENT_NAME — create a site first"

pick_from_list "Select site" "$SITES_JSON" ".name" ".id" \
    || die "No sites available"
SITE_NAME="$REPLY"
SITE_ID="$REPLY_ID"
log_ok "Site: $SITE_NAME (ID: $SITE_ID)"

# --- Agent type --------------------------------------------------------------
print_section "Agent"
echo ""
prompt_choice "Agent type" "Server" "Workstation"
AGENT_TYPE="${REPLY,,}"  # lowercase: server / workstation
log_info "Type: $REPLY"

REPLY=""
prompt_value "Agent description / hostname tag (optional — leave blank to use system hostname)" ""
AGENT_DESC="$REPLY"

# --- Summary & confirm -------------------------------------------------------
print_section "Configuration Summary"
echo ""
echo -e "  ${BOLD}TRMM Server:${RESET}   $TRMM_URL"
echo -e "  ${BOLD}Client:${RESET}        $CLIENT_NAME"
echo -e "  ${BOLD}Site:${RESET}          $SITE_NAME"
echo -e "  ${BOLD}Agent type:${RESET}    $AGENT_TYPE"
[[ -n "$AGENT_DESC" ]] && echo -e "  ${BOLD}Description:${RESET}   $AGENT_DESC"
echo -e "  ${BOLD}OS:${RESET}            $ID $VERSION_ID"
echo ""

prompt_confirm "Proceed with installation" || { echo "Aborted."; exit 0; }

# =============================================================================
# DOWNLOAD AND RUN INSTALLER
# =============================================================================

print_section "Downloading Installer"

# Detect architecture
ARCH="64"
[[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"

INSTALLER_URL="${TRMM_URL}/api/v3/plat/installer/?plat=linux&arch=${ARCH}&token=${TRMM_TOKEN}&client_id=${CLIENT_ID}&site_id=${SITE_ID}&agent_type=${AGENT_TYPE}"
INSTALLER_PATH="/tmp/trmm-agent-install-$$.sh"

log_info "Downloading agent installer (arch: $ARCH)..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$INSTALLER_PATH" "$INSTALLER_URL" 2>/dev/null)

if [[ "$HTTP_CODE" != "200" ]]; then
    rm -f "$INSTALLER_PATH"
    die "Failed to download installer (HTTP $HTTP_CODE) — check API key permissions"
fi

# Sanity check — installer should be a shell script
if ! head -1 "$INSTALLER_PATH" | grep -q '^#!'; then
    rm -f "$INSTALLER_PATH"
    die "Downloaded file does not look like a shell script — check your API key and permissions"
fi

chmod +x "$INSTALLER_PATH"
log_ok "Installer downloaded"

print_section "Installing Agent"
log_info "Running TacticalRMM agent installer..."
echo ""

bash "$INSTALLER_PATH"
INSTALL_EXIT=$?

rm -f "$INSTALLER_PATH"

if [[ $INSTALL_EXIT -ne 0 ]]; then
    die "Installer exited with code $INSTALL_EXIT"
fi

# --- Verify ------------------------------------------------------------------
print_section "Verifying"
sleep 3

if systemctl is-active --quiet tacticalagent 2>/dev/null; then
    log_ok "tacticalagent service is running"
elif systemctl is-active --quiet mesh-agent 2>/dev/null; then
    log_ok "mesh-agent service is running"
else
    log_warn "Could not verify service status — check: systemctl status tacticalagent"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║          TacticalRMM Agent Installed ✔               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Client:${RESET}     $CLIENT_NAME"
echo -e "  ${BOLD}Site:${RESET}       $SITE_NAME"
echo -e "  ${BOLD}Type:${RESET}       $AGENT_TYPE"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  Status:   ${CYAN}systemctl status tacticalagent${RESET}"
echo -e "  Logs:     ${CYAN}journalctl -u tacticalagent -n 50${RESET}"
echo -e "  Restart:  ${CYAN}systemctl restart tacticalagent${RESET}"
echo ""
echo -e "  ${YELLOW}The agent should appear in TacticalRMM within a few seconds.${RESET}"
echo ""
