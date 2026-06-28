#!/usr/bin/env bash
# =============================================================================
# TacticalRMM Agent Updater — Linux (Ubuntu / Debian)
# Community licence edition — recompiles the rmmagent binary from source.
#
# Why this exists:
#   The Linux community agent is compiled from source (amidaware/rmmagent),
#   so the TacticalRMM server CANNOT auto-update it the way it updates the
#   official signed Windows agent. The MeshCentral agent self-updates from the
#   mesh server, but the rmmagent binary will silently drift behind the server
#   version until it is manually rebuilt. This script rebuilds it.
#
# What it does:
#   1. Confirms the agent is installed and records the current version
#   2. Downloads the community install/update script
#   3. Runs its "update" mode — recompiles rmmagent from the latest amidaware
#      source (via Go) and hot-swaps the binary (mesh agent and config untouched)
#   4. Verifies the service is running and reports the version change
#
# Non-interactive and safe to re-run. Intended to be scheduled as a TacticalRMM
# task or a cron job so the Linux agent tracks the server version over time.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/update-tacticalrmm-agent-linux.sh \
#     -o /tmp/update-trmm-agent-linux.sh && sudo bash /tmp/update-trmm-agent-linux.sh
#
#   Via TacticalRMM (optional Discord notification):
#   curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/update-tacticalrmm-agent-linux.sh \
#     | sudo bash -s -- "{{global.DiscordWebhook}}"
#
# Arguments:
#   $1 = Discord webhook URL (optional) — sends an update/failure notification
# =============================================================================

set -uo pipefail

# --- Arguments ---------------------------------------------------------------
DISCORD_WEBHOOK=$(echo "${1:-}" | tr -d "'")

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        TacticalRMM Agent Updater                     ║${RESET}"
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
die()       { echo -e "\n  ${RED}✖  $1${RESET}" >&2; notify_failure "$1"; exit 1; }

# --- Discord notification helpers --------------------------------------------
# SECURITY: Escape a string for safe inclusion in a JSON value.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash
    s="${s//\"/\\\"}"   # double quote
    s="${s//$'\n'/\\n}" # newline
    s="${s//$'\r'/\\r}" # carriage return
    s="${s//$'\t'/\\t}" # tab
    printf '%s' "$s"
}

send_discord() {
    local title="$1" description="$2" color="$3"
    [[ -z "$DISCORD_WEBHOOK" ]] && return 0

    local safe_title safe_desc
    safe_title=$(json_escape "$title")
    safe_desc=$(json_escape "$description")

    local payload
    payload=$(printf '{
  "embeds": [{
    "title": "%s",
    "description": "%s",
    "color": %d,
    "footer": { "text": "TacticalRMM - Linux Agent" },
    "timestamp": "%s"
  }]
}' "$safe_title" "$safe_desc" "$color" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

    curl -s -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK" >/dev/null 2>&1 \
        || log_warn "Discord notification failed"
}

notify_failure() {
    local reason="$1"
    send_discord "❌ TacticalRMM Agent Update Failed" \
        "**Host:** \`${SYS_HOSTNAME:-$(hostname -f 2>/dev/null)}\`\n**IP:** \`${IP_ADDRESS:-$(hostname -I 2>/dev/null | awk '{print $1}')}\`\n**Reason:** ${reason}" \
        15158332
}

# --- Must run as root --------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash update-tacticalrmm-agent-linux.sh"

# --- OS check ----------------------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS"
. /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] \
    || die "Unsupported OS: $ID (Ubuntu and Debian only)"

# --- System info -------------------------------------------------------------
SYS_HOSTNAME=$(hostname -f)
IP_ADDRESS=$(hostname -I | awk '{print $1}')

RMMAGENT_BIN="/usr/local/bin/rmmagent"
SERVICE="tacticalagent"

# --- Read the installed agent version ----------------------------------------
get_version() {
    [[ -x "$RMMAGENT_BIN" ]] || { echo "unknown"; return; }
    local v
    v=$("$RMMAGENT_BIN" -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "${v:-unknown}"
}

print_header

# --- Pre-flight checks -------------------------------------------------------
print_section "Pre-flight"

# The compiled rmmagent binary is the authoritative proof of an existing
# install — the installer always places it here.
[[ -x "$RMMAGENT_BIN" ]] \
    || die "rmmagent not found at $RMMAGENT_BIN — run the installer first (install-tacticalrmm-agent-linux.sh)"

# Detect the systemd unit using several methods — parsing list-unit-files is
# unreliable across systemd versions, so fall back to systemctl cat and the
# known unit-file locations. Missing detection is a warning, not fatal: the
# binary already proves the install, and the post-update step verifies the
# service is active.
service_present() {
    systemctl cat "${SERVICE}.service" >/dev/null 2>&1 && return 0
    systemctl is-enabled "${SERVICE}" >/dev/null 2>&1 && return 0
    systemctl is-active  "${SERVICE}" >/dev/null 2>&1 && return 0
    [[ -f "/etc/systemd/system/${SERVICE}.service" ]]  && return 0
    [[ -f "/lib/systemd/system/${SERVICE}.service" ]]  && return 0
    [[ -f "/usr/lib/systemd/system/${SERVICE}.service" ]] && return 0
    return 1
}

if ! service_present; then
    log_warn "Could not confirm the '${SERVICE}' systemd unit — proceeding on the binary; the update will verify the service afterwards."
fi

PREV_VERSION=$(get_version)
log_ok "Agent installed — current version: $PREV_VERSION"

# --- Dependencies ------------------------------------------------------------
# The community script installs Go itself and handles the compile; we only need
# the tools to fetch and run it. Build tools are already present from install.
for pkg in curl wget tar; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        log_info "Installing $pkg..."
        apt-get install -y -q "$pkg" >/dev/null 2>&1 || die "Could not install $pkg"
    fi
done
# Ensure a Go installed under /usr/local/go is on PATH for non-login shells (cron)
[[ -d /usr/local/go/bin ]] && export PATH="$PATH:/usr/local/go/bin"

# =============================================================================
# UPDATE
# =============================================================================

print_section "Updating Agent"

TMPDIR_WORK=$(mktemp -d /tmp/trmm-update-XXXXXX)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

log_info "Downloading community install/update script..."
COMMUNITY_SCRIPT="$TMPDIR_WORK/rmmagent-linux.sh"
wget -q "https://raw.githubusercontent.com/Nerdy-Technician/LinuxRMM-Script/refs/heads/main/rmmagent-linux.sh" \
    -O "$COMMUNITY_SCRIPT" 2>/dev/null \
    || die "Could not download community script from GitHub"
chmod +x "$COMMUNITY_SCRIPT"

echo ""
log_info "Recompiling rmmagent from the latest source — this may take several minutes."
echo ""

# The community "update" mode recompiles from amidaware master and hot-swaps
# the binary (stop service → replace → start). It takes no arguments and does
# not touch the mesh agent or any agent configuration.
bash "$COMMUNITY_SCRIPT" --simple update
UPDATE_EXIT=$?
if [[ $UPDATE_EXIT -ne 0 ]]; then
    die "Community update script exited with code $UPDATE_EXIT"
fi

# =============================================================================
# VERIFY
# =============================================================================

print_section "Verifying"

sleep 2
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    log_ok "${SERVICE} service is running"
else
    systemctl status "$SERVICE" --no-pager || true
    die "${SERVICE} failed to start — check: journalctl -u ${SERVICE} -n 50"
fi

NEW_VERSION=$(get_version)

# =============================================================================
# SUMMARY & NOTIFY
# =============================================================================

if [[ "$PREV_VERSION" == "$NEW_VERSION" ]]; then
    VERSION_MSG="**Version:** \`$NEW_VERSION\` (already latest — rebuilt from source)"
    SUMMARY_LINE="Already on the latest source build: $NEW_VERSION"
    COLOR=3066993
else
    VERSION_MSG="**Version:** \`$PREV_VERSION\` -> \`$NEW_VERSION\`"
    SUMMARY_LINE="Updated: $PREV_VERSION -> $NEW_VERSION"
    COLOR=3447003
fi

send_discord "✅ TacticalRMM Agent Updated" \
    "**Host:** \`$SYS_HOSTNAME\`\n**IP:** \`$IP_ADDRESS\`\n${VERSION_MSG}" \
    "$COLOR"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║          TacticalRMM Agent Updated ✔                 ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}${SUMMARY_LINE}${RESET}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  Status:   ${CYAN}systemctl status ${SERVICE}${RESET}"
echo -e "  Logs:     ${CYAN}journalctl -u ${SERVICE} -n 50${RESET}"
echo -e "  Version:  ${CYAN}${RMMAGENT_BIN} -version${RESET}"
echo ""
