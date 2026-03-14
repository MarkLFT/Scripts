#!/usr/bin/env bash
# =============================================================================
# TacticalRMM Agent Installer — Linux (Ubuntu / Debian)
# Community licence edition — no signed agent required.
#
# Install flow:
#   1. Connects to your TRMM API to list clients and sites
#   2. Gets mesh URL automatically from API
#   3. Prompts for the auth token (generate in TRMM UI)
#   4. Downloads and installs the mesh agent
#   5. Downloads and installs the rmmagent binary
#
# Auth token: In TacticalRMM → Agents → Install Agent → select Windows
#             → Manual → copy the value shown after --auth
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

# --- Architecture ------------------------------------------------------------
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv6l)  ARCH="armv6" ;;
    i386|i686) ARCH="x86" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

# --- Dependencies ------------------------------------------------------------
for pkg in curl wget jq; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        log_info "Installing $pkg..."
        apt-get install -y -q "$pkg" >/dev/null 2>&1 || die "Could not install $pkg"
    fi
done

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
# TRMM API HELPER
# =============================================================================

TRMM_URL=""
TRMM_TOKEN=""

trmm_get() {
    local endpoint="$1"
    curl -s -X GET "${TRMM_URL}/${endpoint}" \
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

log_info "Testing connection..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-KEY: ${TRMM_TOKEN}" "${TRMM_URL}/clients/" 2>/dev/null)
if [[ "$HTTP_CODE" == "200" ]]; then
    log_ok "Connected successfully"
elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    die "Authentication failed (HTTP $HTTP_CODE) — check your API key"
else
    die "Could not reach TacticalRMM (HTTP $HTTP_CODE) — check the URL"
fi

# --- Get mesh settings from API ----------------------------------------------
CORE_SETTINGS=$(trmm_get "core/settings/")
MESH_SITE=$(echo "$CORE_SETTINGS" | jq -r '.mesh_site // empty')
MESH_TOKEN=$(echo "$CORE_SETTINGS" | jq -r '.mesh_token // empty')
[[ -z "$MESH_SITE" ]]  && die "Could not get mesh URL from API"
[[ -z "$MESH_TOKEN" ]] && die "Could not get mesh token from API"
MESH_FQDN="${MESH_SITE#https://}"
MESH_FQDN="${MESH_FQDN#http://}"
log_ok "Mesh server: $MESH_SITE"

# --- Select client -----------------------------------------------------------
print_section "Client"
log_info "Loading clients..."
CLIENTS_JSON=$(trmm_get "clients/")
CLIENT_COUNT=$(echo "$CLIENTS_JSON" | jq 'length' 2>/dev/null || echo "0")
[[ "$CLIENT_COUNT" -eq 0 ]] && die "No clients found — create a client in TacticalRMM first"

pick_from_list "Select client" "$CLIENTS_JSON" ".name" ".id" \
    || die "No clients available"
CLIENT_NAME="$REPLY"
CLIENT_ID="$REPLY_ID"
log_ok "Client: $CLIENT_NAME (ID: $CLIENT_ID)"

# --- Select site (embedded in clients response) ------------------------------
print_section "Site"
log_info "Loading sites for $CLIENT_NAME..."
SITES_JSON=$(echo "$CLIENTS_JSON" | jq --argjson cid "${CLIENT_ID}" \
    '[.[] | select(.id == $cid) | .sites[]]')
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
AGENT_TYPE="${REPLY,,}"
log_info "Type: $REPLY"

# --- Auth token --------------------------------------------------------------
print_section "Auth Token"
echo -e "  ${YELLOW}In TacticalRMM: Agents → Install Agent${RESET}"
echo -e "  ${YELLOW}Select: Windows, Manual installation method${RESET}"
echo -e "  ${YELLOW}Click 'Show Manual Instructions' and copy the value after --auth${RESET}"
echo ""
SECRET_REPLY=""
prompt_secret "Auth token"
AUTH_TOKEN="$SECRET_REPLY"

# --- Summary & confirm -------------------------------------------------------
print_section "Configuration Summary"
echo ""
echo -e "  ${BOLD}TRMM API:${RESET}     $TRMM_URL"
echo -e "  ${BOLD}Mesh server:${RESET}  $MESH_SITE"
echo -e "  ${BOLD}Client:${RESET}       $CLIENT_NAME (ID: $CLIENT_ID)"
echo -e "  ${BOLD}Site:${RESET}         $SITE_NAME (ID: $SITE_ID)"
echo -e "  ${BOLD}Agent type:${RESET}   $AGENT_TYPE"
echo -e "  ${BOLD}Architecture:${RESET} $ARCH"
echo ""

prompt_confirm "Proceed with installation" || { echo "Aborted."; exit 0; }

# =============================================================================
# INSTALL AGENT USING NERDY-TECHNICIAN COMMUNITY SCRIPT
# =============================================================================
# This script compiles rmmagent from source and handles everything including
# the mesh agent install. Source: github.com/Nerdy-Technician/LinuxRMM-Script

print_section "Installing Agent"

TMPDIR_WORK=$(mktemp -d /tmp/trmm-install-XXXXXX)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Get the mesh agent URL from your mesh server
# Build the base mesh agent URL — the community script appends installflags and meshinstall itself
MESH_AGENT_URL="${MESH_SITE}/meshagents?id=${MESH_TOKEN}"

log_info "Downloading community install script..."
COMMUNITY_SCRIPT="$TMPDIR_WORK/rmmagent-linux.sh"
wget -q "https://raw.githubusercontent.com/Nerdy-Technician/LinuxRMM-Script/refs/heads/main/rmmagent-linux.sh" \
    -O "$COMMUNITY_SCRIPT" 2>/dev/null \
    || die "Could not download community install script from GitHub"

chmod +x "$COMMUNITY_SCRIPT"

echo ""
log_info "Running community agent installer..."
log_info "Note: This will install Go and compile the agent — may take several minutes."
echo ""

# Run with --simple flag for cleaner output
bash "$COMMUNITY_SCRIPT" --simple install \
    "${MESH_AGENT_URL}" \
    "${TRMM_URL}" \
    "${CLIENT_ID}" \
    "${SITE_ID}" \
    "${AUTH_TOKEN}" \
    "${AGENT_TYPE}"

INSTALL_EXIT=$?
if [[ $INSTALL_EXIT -ne 0 ]]; then
    die "Agent installer exited with code $INSTALL_EXIT"
fi

# =============================================================================
# VERIFY
# =============================================================================

print_section "Verifying"

if systemctl is-active --quiet tacticalagent 2>/dev/null; then
    log_ok "tacticalagent service is running"
else
    systemctl status tacticalagent --no-pager || true
    die "tacticalagent failed to start — check: journalctl -u tacticalagent -n 50"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║          TacticalRMM Agent Installed ✔               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Client:${RESET}  $CLIENT_NAME"
echo -e "  ${BOLD}Site:${RESET}    $SITE_NAME"
echo -e "  ${BOLD}Type:${RESET}    $AGENT_TYPE"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  Status:   ${CYAN}systemctl status tacticalagent${RESET}"
echo -e "  Logs:     ${CYAN}journalctl -u tacticalagent -n 50${RESET}"
echo -e "  Restart:  ${CYAN}systemctl restart tacticalagent${RESET}"
echo ""
echo -e "  ${YELLOW}The agent should appear in TacticalRMM within a few seconds.${RESET}"
echo ""
