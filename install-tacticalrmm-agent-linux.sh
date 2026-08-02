#!/usr/bin/env bash
# =============================================================================
# TacticalRMM Agent Installer — Linux (Ubuntu / Debian)
# Community licence edition — no signed agent required.
#
# Install flow:
#   1. Connects to your TRMM API to list clients and sites
#   2. Prompts for the auth token (generate in TRMM UI)
#   3. Downloads a pinned, checksum-verified community build script
#   4. Compiles the rmmagent binary from the amidaware source
#   5. Registers the agent and installs the systemd service
#
# The MeshCentral agent is NOT installed. TRMM v1.5.0 introduced a native web
# terminal with no MeshCentral dependency (requires agent 2.11.0+), which covers
# shell access on headless servers. Take Control and File Browser still require
# MeshCentral — if you need them, install the mesh agent first from
# MeshCentral → device group → Add Agent → Installation Executable, then re-run
# this script: it detects an existing mesh agent and links its node id.
#
# Auth token: In TacticalRMM → Agents → Install Agent → select Windows
#             → Manual → copy the value shown after --auth
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-tacticalrmm-agent-linux.sh \
#     -o /tmp/install-tacticalrmm-agent-linux.sh && sudo bash /tmp/install-tacticalrmm-agent-linux.sh
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
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash install-tacticalrmm-agent-linux.sh"

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
for pkg in curl wget jq tar; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        log_info "Installing $pkg..."
        apt-get install -y -q "$pkg" >/dev/null 2>&1 || die "Could not install $pkg"
    fi
done
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found — cannot verify the build script"

# --- Pinned community build script -------------------------------------------
# The rmmagent binary is compiled from source (community licence — the prebuilt
# Linux agent requires a Tier 1 sponsorship). The build is driven by a third
# party script, so it is pinned to a specific commit and checksum-verified
# before execution rather than tracked from a moving branch head.
# Re-pin with:
#   git ls-remote https://github.com/Nerdy-Technician/LinuxRMM-Script.git refs/heads/main
#   curl -fsSL https://raw.githubusercontent.com/Nerdy-Technician/LinuxRMM-Script/<commit>/rmmagent-linux.sh | sha256sum
# Keep this in step with update-tacticalrmm-agent-linux.sh.
COMMUNITY_REPO="Nerdy-Technician/LinuxRMM-Script"
COMMUNITY_COMMIT="8da32b054a39292a114689730dd72540b1b8432c"
COMMUNITY_SHA256="d0558e5d2fc8c1a9ca700845296315cdf5081925acbdaf9e84e24f1e8b9fb3cc"
COMMUNITY_URL="https://raw.githubusercontent.com/${COMMUNITY_REPO}/${COMMUNITY_COMMIT}/rmmagent-linux.sh"

# --- Build environment -------------------------------------------------------
# Ensure a Go installed under /usr/local/go is on PATH for non-login shells, and
# pin HOME and the Go cache/module paths — with a stripped environment `go build`
# aborts instantly with "GOCACHE is not defined" before a single module downloads.
[[ -d /usr/local/go/bin ]] && export PATH="$PATH:/usr/local/go/bin"
[[ -n "${HOME:-}" && -w "${HOME:-/nonexistent}" ]] || export HOME=/root
export GOCACHE="${GOCACHE:-$HOME/.cache/go-build}"
export GOPATH="${GOPATH:-$HOME/go}"
mkdir -p "$GOCACHE" "$GOPATH" 2>/dev/null || true

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
echo -e "  ${BOLD}Client:${RESET}       $CLIENT_NAME (ID: $CLIENT_ID)"
echo -e "  ${BOLD}Site:${RESET}         $SITE_NAME (ID: $SITE_ID)"
echo -e "  ${BOLD}Agent type:${RESET}   $AGENT_TYPE"
echo -e "  ${BOLD}Architecture:${RESET} $ARCH"
if [[ -x /opt/tacticalmesh/meshagent ]]; then
    echo -e "  ${BOLD}MeshCentral:${RESET}  existing agent detected — node id will be linked"
else
    echo -e "  ${BOLD}MeshCentral:${RESET}  not installed (Take Control / File Browser unavailable)"
fi
echo ""

prompt_confirm "Proceed with installation" || { echo "Aborted."; exit 0; }

# =============================================================================
# BUILD THE AGENT BINARY
# =============================================================================
# The community script (github.com/Nerdy-Technician/LinuxRMM-Script) is used as
# a BUILD STEP ONLY: it installs Go and compiles rmmagent from the amidaware
# source. Its mesh install is patched out, and its own registration/service
# setup is replaced by a plain binary install so that registration happens in
# this script instead — that is what makes --meshnodeid possible, and it means
# the auth token and API URL are never passed to a third-party script.

print_section "Building Agent"

TMPDIR_WORK=$(mktemp -d /tmp/trmm-install-XXXXXX)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

COMMUNITY_SCRIPT="$TMPDIR_WORK/rmmagent-linux.sh"

log_info "Downloading pinned build script (${COMMUNITY_COMMIT:0:12})..."
curl -fsSL "$COMMUNITY_URL" -o "$COMMUNITY_SCRIPT" \
    || die "Could not download the pinned build script from GitHub"

ACTUAL_SHA256=$(sha256sum "$COMMUNITY_SCRIPT" | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$COMMUNITY_SHA256" ]]; then
    die "Build script checksum mismatch — refusing to execute.
     Expected: $COMMUNITY_SHA256
     Actual:   $ACTUAL_SHA256
     Re-pin COMMUNITY_COMMIT/COMMUNITY_SHA256 after reviewing upstream changes."
fi
log_ok "Build script verified (SHA-256 matches pin)"

# Patch the community dispatcher. Each patch asserts exactly one match before
# and none after — if upstream restructures the script we abort rather than
# silently run something that no longer does what we expect.
patch_community_script() {
    local label="$1" pattern="$2" replacement="$3" before after
    before=$(grep -cE "$pattern" "$COMMUNITY_SCRIPT" 2>/dev/null || true)
    if [[ "$before" -ne 1 ]]; then
        die "Build script patch '${label}' expected exactly 1 match, found ${before}.
     Upstream ${COMMUNITY_REPO} has changed — review it and re-pin COMMUNITY_COMMIT/COMMUNITY_SHA256."
    fi
    sed -i -E "s|${pattern}|${replacement}|" "$COMMUNITY_SCRIPT"
    after=$(grep -cE "$pattern" "$COMMUNITY_SCRIPT" 2>/dev/null || true)
    [[ "$after" -eq 0 ]] \
        || die "Build script patch '${label}' did not apply cleanly (${after} match(es) remain)."
    log_ok "Patched build script: ${label}"
}

patch_community_script "mesh install disabled" \
    '^[[:space:]]*install_mesh[[:space:]]*$' \
    '        : # mesh install disabled — see README (MeshCentral on Linux)'

# The compiled binary lands in /tmp/temp_rmmagent, which the community script's
# own EXIT trap deletes, so it must be moved into place from inside that run.
# `install` unlinks the destination first, so this is safe even when the old
# agent is still running (a plain `cp` would fail with ETXTBSY).
patch_community_script "register/service handled by this script" \
    '^[[:space:]]*install_agent[[:space:]]*$' \
    '        install -m 0755 /tmp/temp_rmmagent /usr/local/bin/rmmagent'

# Source tarball that the community script compiles from. Its own download is a
# single `wget -q` with no retries under `set -e`, so any transient HTTP error
# from GitHub aborts the whole run instantly (observed as wget exit 8 when many
# agents hit codeload at once). Fetch it here with retry+backoff and neutralise
# the community download so it reuses our copy.
AGENT_SRC_URL="https://github.com/amidaware/rmmagent/archive/refs/heads/master.tar.gz"
AGENT_SRC_TARBALL="/tmp/rmmagent.tar.gz"

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
[[ "$SRC_OK" -eq 1 ]] || die "Could not download the agent source after 5 attempts"

SRC_PATCH_RE='^[[:space:]]*wget .*-O /tmp/rmmagent\.tar\.gz.*$'
SRC_PATCH_MATCHES=$(grep -cE "$SRC_PATCH_RE" "$COMMUNITY_SCRIPT" 2>/dev/null || true)
if [[ "$SRC_PATCH_MATCHES" -gt 0 ]]; then
    sed -i -E "s|${SRC_PATCH_RE}|: # source pre-fetched by installer|" "$COMMUNITY_SCRIPT"
    log_ok "Using the pre-fetched source (${SRC_PATCH_MATCHES} download line(s) neutralised)"
else
    log_warn "Could not neutralise the community source download — it will fetch the source itself"
fi

echo ""
log_info "Compiling the agent from source — this may take several minutes."
echo ""

# Run WITHOUT --simple so real go build output is visible — --simple sends the
# compile to /dev/null, which hides the actual error behind a bare exit code.
BUILD_LOG="$TMPDIR_WORK/community-build.log"
bash "$COMMUNITY_SCRIPT" install 2>&1 | tee "$BUILD_LOG"
BUILD_EXIT=${PIPESTATUS[0]}
if [[ $BUILD_EXIT -ne 0 ]]; then
    log_warn "Last lines of build output:"
    tail -n 30 "$BUILD_LOG" 2>/dev/null | sed 's/^/      /'
    die "Build script exited with code $BUILD_EXIT"
fi

[[ -x /usr/local/bin/rmmagent ]] \
    || die "Build reported success but /usr/local/bin/rmmagent is missing"
log_ok "Agent binary built: $(/usr/local/bin/rmmagent -version 2>/dev/null | head -1)"

# =============================================================================
# REGISTER AGENT
# =============================================================================
# Everything above this point is network work. Only now that the binary exists
# is any previous install disturbed — a failed download leaves the running
# agent untouched.

print_section "Registering Agent"

if systemctl is-active --quiet tacticalagent 2>/dev/null; then
    log_info "Stopping the existing tacticalagent service..."
    systemctl stop tacticalagent || die "Could not stop the existing tacticalagent service"
fi
rm -rf /etc/tacticalagent

# Link an existing MeshCentral agent if one is present. This script never
# installs mesh, but a host that already has it should still get Take Control
# and File Browser, which need the node id recorded against the agent.
MESH_NODE_ID=""
if [[ -x /opt/tacticalmesh/meshagent ]]; then
    MESH_NODE_ID=$(env XAUTHORITY=foo DISPLAY=bar /usr/local/bin/rmmagent -m nixmeshnodeid 2>/dev/null | tr -d '\r\n')
    # On failure the agent returns the literal string "error getting meshnodeid"
    # rather than an empty value, so validate the shape before trusting it — a
    # bogus id would otherwise be recorded silently against the agent. The
    # pattern is held in a variable so bash does not expand $_ inside it.
    # shellcheck disable=SC2016  # literal regex, expansion is exactly what we avoid
    MESH_ID_RE='^[A-Za-z0-9@$_=/+-]{20,}$'
    if [[ "$MESH_NODE_ID" =~ $MESH_ID_RE ]]; then
        log_ok "Existing mesh agent found — linking node id"
    elif [[ -n "$MESH_NODE_ID" ]]; then
        log_warn "Mesh agent present but returned no usable node id (\"${MESH_NODE_ID}\") — registering without it"
        MESH_NODE_ID=""
    else
        log_warn "Mesh agent present but its node id could not be read — registering without it"
    fi
else
    log_info "No mesh agent present — registering without a mesh node id"
fi

REGISTER_CMD=(/usr/local/bin/rmmagent -m install
    -api "$TRMM_URL"
    -client-id "$CLIENT_ID"
    -site-id "$SITE_ID"
    -agent-type "$AGENT_TYPE"
    -auth "$AUTH_TOKEN")
[[ -n "$MESH_NODE_ID" ]] && REGISTER_CMD+=(--meshnodeid "$MESH_NODE_ID")

"${REGISTER_CMD[@]}" || die "Agent registration failed — check the output above (is the auth token still valid?)"
log_ok "Agent registered with TacticalRMM"

# --- systemd service ---------------------------------------------------------
cat >/etc/systemd/system/tacticalagent.service <<'EOF'
[Unit]
Description=Tactical RMM Linux Agent
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rmmagent -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload || die "systemctl daemon-reload failed"
systemctl enable tacticalagent >/dev/null 2>&1 || die "Could not enable the tacticalagent service"
systemctl restart tacticalagent || die "Could not start the tacticalagent service"

# =============================================================================
# VERIFY
# =============================================================================

print_section "Verifying"

sleep 2
if systemctl is-active --quiet tacticalagent 2>/dev/null; then
    log_ok "tacticalagent service is running"
else
    systemctl status tacticalagent --no-pager || true
    die "tacticalagent failed to start — check: journalctl -u tacticalagent -n 50"
fi

AGENT_VERSION=$(/usr/local/bin/rmmagent -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
log_ok "Agent version: ${AGENT_VERSION:-unknown}"

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
echo -e "  ${BOLD}Version:${RESET} ${AGENT_VERSION:-unknown}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  Status:   ${CYAN}systemctl status tacticalagent${RESET}"
echo -e "  Logs:     ${CYAN}journalctl -u tacticalagent -n 50${RESET}"
echo -e "  Restart:  ${CYAN}systemctl restart tacticalagent${RESET}"
echo ""
if [[ -n "$MESH_NODE_ID" ]]; then
    echo -e "  ${BOLD}MeshCentral:${RESET} existing agent linked — Take Control and File Browser available."
else
    echo -e "  ${YELLOW}MeshCentral is not installed. Take Control and File Browser will not${RESET}"
    echo -e "  ${YELLOW}work; the native web terminal (TRMM v1.5.0+, agent 2.11.0+) will.${RESET}"
    echo -e "  ${YELLOW}Terminal access needs the 'Use Terminal' role permission.${RESET}"
fi
echo ""
echo -e "  ${YELLOW}The agent should appear in TacticalRMM within a few seconds.${RESET}"
echo ""
