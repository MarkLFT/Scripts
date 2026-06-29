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

# Ensure a sane build environment. When this runs from a detached systemd unit
# (the TacticalRMM bootstrap) the environment is stripped and HOME is unset, so
# `go build` cannot locate a build cache and aborts INSTANTLY with "GOCACHE is
# not defined" — exit 1 before a single module downloads. Pin HOME and the Go
# cache/module paths to a writable location so the compile runs in any context.
[[ -n "${HOME:-}" && -w "${HOME:-/nonexistent}" ]] || export HOME=/root
export GOCACHE="${GOCACHE:-$HOME/.cache/go-build}"
export GOPATH="${GOPATH:-$HOME/go}"
mkdir -p "$GOCACHE" "$GOPATH" 2>/dev/null || true
log_info "Build env: HOME=$HOME GOCACHE=$GOCACHE"

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

# Source tarball that the community script compiles from. Its own download is a
# single `wget -q` with no retries under `set -e`, so any transient HTTP error
# from GitHub aborts the whole run instantly (observed once as wget exit 8). We
# fetch it ourselves with retry+backoff and neutralise the community script's
# download so it reuses our copy.
AGENT_SRC_URL="https://github.com/amidaware/rmmagent/archive/refs/heads/master.tar.gz"
AGENT_SRC_TARBALL="/tmp/rmmagent.tar.gz"

# Small stagger before the network step, in case a scheduled fleet-wide run fires
# many agents at once. Non-interactive only — manual SSH runs aren't delayed.
if [[ ! -t 1 ]]; then
    JITTER=$(( RANDOM % 45 ))
    [[ "$JITTER" -gt 0 ]] && { log_info "Staggering fleet load — waiting ${JITTER}s..."; sleep "$JITTER"; }
fi

log_info "Pre-fetching agent source with retries..."
SRC_OK=0
for attempt in 1 2 3 4 5; do
    if curl -fsSL "$AGENT_SRC_URL" -o "$AGENT_SRC_TARBALL" 2>/dev/null && [[ -s "$AGENT_SRC_TARBALL" ]]; then
        SRC_OK=1
        log_ok "Source downloaded ($(du -h "$AGENT_SRC_TARBALL" 2>/dev/null | cut -f1))"
        break
    fi
    log_warn "Source fetch attempt ${attempt}/5 failed — retrying in $((attempt*8))s..."
    sleep $((attempt*8))
done

if [[ "$SRC_OK" -eq 1 ]]; then
    # Replace any wget line in the community script that writes the tarball with a
    # no-op, so it compiles from the copy we just fetched. If this fails to match
    # (upstream changed), the community script simply downloads it as before — no
    # worse than the current behaviour.
    sed -i 's|^[[:space:]]*wget .*-O /tmp/rmmagent.tar.gz.*$|: # source pre-fetched by updater|' "$COMMUNITY_SCRIPT"
else
    log_warn "Pre-fetch failed after retries — letting the community script fetch the source itself"
fi

echo ""
log_info "Recompiling rmmagent from the latest source — this may take several minutes."
echo ""

# The community "update" mode recompiles from amidaware master and hot-swaps
# the binary (stop service → replace → start). It takes no arguments and does
# not touch the mesh agent or any agent configuration. Retry once as a backstop
# for transient failures during the Go module fetch (compile is local only, and
# the service is not touched until the build succeeds, so a retry is safe).
# NOTE: run WITHOUT --simple so the real go build output is visible — --simple
# sends the compile to /dev/null, which previously hid the actual error and made
# failures show only as a bare exit code. Capture it so a failure prints the tail.
UPDATE_LOG="$TMPDIR_WORK/community-update.log"
UPDATE_EXIT=1
for attempt in 1 2; do
    bash "$COMMUNITY_SCRIPT" update 2>&1 | tee "$UPDATE_LOG"
    UPDATE_EXIT=${PIPESTATUS[0]}
    [[ $UPDATE_EXIT -eq 0 ]] && break
    [[ $attempt -lt 2 ]] && { log_warn "Update attempt ${attempt} failed (exit ${UPDATE_EXIT}) — retrying in 20s..."; sleep 20; }
done
if [[ $UPDATE_EXIT -ne 0 ]]; then
    log_warn "Last lines of community update output:"
    tail -n 30 "$UPDATE_LOG" 2>/dev/null | sed 's/^/      /'
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
