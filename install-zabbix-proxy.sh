#!/usr/bin/env bash
# =============================================================================
# Zabbix Proxy - Interactive Installer (Debian) — Standard Edition
# Supports: Debian 11 (Bullseye), Debian 12 (Bookworm), Debian 13 (Trixie)
#
# Fixed settings (not prompted):
#   Mode        : Active (proxy dials out — no inbound firewall rule needed)
#   Database    : SQLite3 (zero setup, perfect for most sites)
#   Performance : Tuned for a small LAN (~12 agents)
#
# Prompts for: Zabbix version, hostname, port, server address, PSK
#
# Usage:
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-zabbix-proxy.sh)
#   sudo ./install-zabbix-proxy.sh
# =============================================================================

set -uo pipefail

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        Zabbix Proxy - Interactive Installer          ║${RESET}"
    echo -e "${CYAN}${BOLD}║        Active mode  •  SQLite3  •  Small LAN        ║${RESET}"
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
log_warn()  { echo -e "  ${YELLOW}⚠${RESET}  $1" >&2; }
die()       { echo -e "\n  ${RED}✖  $1${RESET}" >&2; exit 1; }

# --- Must run as root --------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run as root: sudo ./install-zabbix-proxy.sh"

# --- Detect Debian version ---------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release missing"
. /etc/os-release
[[ "$ID" == "debian" ]] || die "Debian only (detected: $ID)"

case "$VERSION_CODENAME" in
    bullseye) OS_VER="11" ;;
    bookworm)  OS_VER="12" ;;
    trixie)    OS_VER="13" ;;
    *) die "Unsupported Debian version: $VERSION_CODENAME (supported: bullseye, bookworm, trixie)" ;;
esac

# =============================================================================
# FIXED SETTINGS
# =============================================================================

PROXY_MODE=0
PROXY_MODE_LABEL="Active"
PROXY_PACKAGE="zabbix-proxy-sqlite3"
SQLITE_DB_PATH="/var/lib/zabbix/zabbix_proxy.db"
DB_TYPE="SQLite3"

# Performance — small LAN (~12 agents)
START_POLLERS=3
START_PREPROCESSORS=2
START_HTTP_POLLERS=1
START_IPMI_POLLERS=0
CONFIG_FREQUENCY=300
DATA_SENDER_FREQUENCY=5
PROXY_LOCAL_BUFFER=3600

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

generate_psk() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 32
    else
        cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64
    fi
}

# =============================================================================
# COLLECT CONFIGURATION
# =============================================================================

print_header

# --- Zabbix version ----------------------------------------------------------
print_section "Zabbix Version"
REPLY=""
prompt_value "Zabbix major.minor version" "7.4"
ZABBIX_VERSION="$REPLY"
[[ "$ZABBIX_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "Version must be in x.y format (e.g. 7.4)"

# --- Proxy identity ----------------------------------------------------------
print_section "Proxy Identity"
REPLY=""
prompt_value "Proxy hostname (must match the name you will enter in Zabbix UI)" "$(hostname -f)"
PROXY_HOSTNAME="$REPLY"

REPLY=""
prompt_value "Proxy listen port" "10051"
PROXY_PORT="$REPLY"
[[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Port must be a number"

# --- Zabbix server -----------------------------------------------------------
print_section "Zabbix Server"
REPLY=""
prompt_value "Zabbix server IP or hostname" ""
ZABBIX_SERVER="$REPLY"

REPLY=""
prompt_value "Zabbix server port" "10051"
ZABBIX_SERVER_PORT="$REPLY"

# --- PSK encryption ----------------------------------------------------------
print_section "Encryption (PSK)"
echo -e "  PSK encryption is strongly recommended for proxy-server communication."
echo ""

USE_PSK=false
if prompt_confirm "Enable PSK encryption"; then
    USE_PSK=true
    echo ""
    prompt_choice "PSK option" "Generate automatically" "Enter manually"
    PSK_CHOICE="$REPLY"

    if [[ "$PSK_CHOICE" == "Generate automatically" ]]; then
        PSK_VALUE=$(generate_psk)
        log_ok "PSK generated (256-bit)"
    else
        echo -e "\n  ${YELLOW}Must be a hex string — 64 hex characters = 256-bit.${RESET}"
        SECRET_REPLY=""
        prompt_secret "PSK value (hex string)"
        PSK_VALUE="$SECRET_REPLY"
    fi

    REPLY=""
    prompt_value "PSK identity (label — must match what you enter in Zabbix UI)" "PSK_${PROXY_HOSTNAME}"
    PSK_IDENTITY="$REPLY"

    PSK_FILE="/etc/zabbix/zabbix_proxy.psk"
fi

# --- Summary & confirm -------------------------------------------------------
print_section "Configuration Summary"
echo ""
echo -e "  ${BOLD}Debian:${RESET}          $VERSION_CODENAME ($OS_VER)"
echo -e "  ${BOLD}Zabbix version:${RESET}  $ZABBIX_VERSION"
echo -e "  ${BOLD}Proxy hostname:${RESET}  $PROXY_HOSTNAME"
echo -e "  ${BOLD}Proxy port:${RESET}      $PROXY_PORT"
echo -e "  ${BOLD}Mode:${RESET}            Active (proxy dials out)"
echo -e "  ${BOLD}Zabbix server:${RESET}   $ZABBIX_SERVER:$ZABBIX_SERVER_PORT"
echo -e "  ${BOLD}Database:${RESET}        SQLite3 ($SQLITE_DB_PATH)"
echo -e "  ${BOLD}PSK:${RESET}             $([ "$USE_PSK" == "true" ] && echo "Enabled (identity: $PSK_IDENTITY)" || echo "Disabled")"
echo ""
echo -e "  ${BOLD}Performance (small LAN ~12 agents):${RESET}"
echo -e "    Pollers            $START_POLLERS"
echo -e "    Preprocessors      $START_PREPROCESSORS"
echo -e "    HTTP pollers       $START_HTTP_POLLERS"
echo -e "    Config frequency   ${CONFIG_FREQUENCY}s"
echo -e "    Data sender        ${DATA_SENDER_FREQUENCY}s"
echo -e "    Local buffer       ${PROXY_LOCAL_BUFFER}s"
echo ""

prompt_confirm "Proceed with installation" || { echo "Aborted."; exit 0; }

# =============================================================================
# INSTALLATION
# =============================================================================

print_section "Installing Zabbix Repository"

ZABBIX_REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+debian${OS_VER}_all.deb"
ZABBIX_REPO_URL_ALT="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+debian_all.deb"

TMP_DEB=$(mktemp /tmp/zabbix-release-XXXXXX.deb)
trap 'rm -f "$TMP_DEB"' EXIT

log_info "Downloading Zabbix ${ZABBIX_VERSION} release package..."
if ! curl -fsSL "$ZABBIX_REPO_URL" -o "$TMP_DEB" 2>/dev/null; then
    log_warn "Primary URL failed, trying fallback..."
    curl -fsSL "$ZABBIX_REPO_URL_ALT" -o "$TMP_DEB" \
        || die "Could not download Zabbix release package"
fi

dpkg -i "$TMP_DEB" >/dev/null 2>&1 || true
apt-get update -qq
log_ok "Repository added"

# --- Install packages --------------------------------------------------------
print_section "Installing Packages"
log_info "Installing $PROXY_PACKAGE..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$PROXY_PACKAGE"
log_ok "Package installed"

# --- Prepare SQLite directory ------------------------------------------------
print_section "Preparing Database"
SQLITE_DIR=$(dirname "$SQLITE_DB_PATH")
mkdir -p "$SQLITE_DIR"
chown zabbix:zabbix "$SQLITE_DIR"
chmod 750 "$SQLITE_DIR"
log_ok "SQLite directory ready: $SQLITE_DIR"
log_info "Database file will be created automatically on first start"

# --- Write PSK file ----------------------------------------------------------
if [[ "$USE_PSK" == "true" ]]; then
    print_section "Writing PSK File"
    mkdir -p "$(dirname "$PSK_FILE")"
    echo -n "$PSK_VALUE" > "$PSK_FILE"
    chown zabbix:zabbix "$PSK_FILE"
    chmod 640 "$PSK_FILE"
    log_ok "PSK written to $PSK_FILE"
fi

# --- Write proxy configuration -----------------------------------------------
print_section "Writing Proxy Configuration"

PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
PROXY_LOG="/var/log/zabbix/zabbix_proxy.log"
PROXY_PID="/run/zabbix/zabbix_proxy.pid"

mkdir -p /var/log/zabbix
chown zabbix:zabbix /var/log/zabbix

if [[ "$USE_PSK" == "true" ]]; then
    PSK_BLOCK="TLSConnect=psk
TLSAccept=psk
TLSPSKFile=${PSK_FILE}
TLSPSKIdentity=${PSK_IDENTITY}"
else
    PSK_BLOCK="# TLS/PSK not configured
# To enable: set TLSConnect, TLSAccept, TLSPSKFile, TLSPSKIdentity"
fi

cat > "$PROXY_CONF" <<EOF
# =============================================================================
# Zabbix Proxy Configuration
# Generated $(date)
# Mode: Active | DB: SQLite3 | Scale: Small LAN
# =============================================================================

Hostname=${PROXY_HOSTNAME}
ProxyMode=0

Server=${ZABBIX_SERVER}
ServerPort=${ZABBIX_SERVER_PORT}

ListenIP=0.0.0.0
ListenPort=${PROXY_PORT}

LogFile=${PROXY_LOG}
LogFileSize=20
DebugLevel=3
PidFile=${PROXY_PID}

DBName=${SQLITE_DB_PATH}

${PSK_BLOCK}

StartPollers=${START_POLLERS}
StartIPMIPollers=${START_IPMI_POLLERS}
StartPreprocessingWorkers=${START_PREPROCESSORS}
StartHTTPPollers=${START_HTTP_POLLERS}
StartJavaPollers=0

ProxyConfigFrequency=${CONFIG_FREQUENCY}
ProxyDataSenderFrequency=${DATA_SENDER_FREQUENCY}

ProxyLocalBuffer=${PROXY_LOCAL_BUFFER}
ProxyOfflineBuffer=${PROXY_LOCAL_BUFFER}

Timeout=10
EOF

chown root:zabbix "$PROXY_CONF"
chmod 640 "$PROXY_CONF"
log_ok "Configuration written to $PROXY_CONF"

# --- Enable and start --------------------------------------------------------
print_section "Starting Service"
systemctl daemon-reload
systemctl enable zabbix-proxy --quiet
systemctl restart zabbix-proxy
sleep 3

if systemctl is-active --quiet zabbix-proxy; then
    log_ok "zabbix-proxy is running"
else
    systemctl status zabbix-proxy --no-pager || true
    die "zabbix-proxy failed to start — check: journalctl -u zabbix-proxy -n 50"
fi

# --- Firewall ----------------------------------------------------------------
print_section "Firewall"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    log_info "UFW is active. Active mode dials OUT — no inbound rule needed for normal operation."
    if prompt_confirm "Open port ${PROXY_PORT}/tcp anyway (for status queries or passive checks)" "n"; then
        ufw allow "${PROXY_PORT}/tcp" comment "Zabbix Proxy" >/dev/null
        log_ok "UFW rule added for port ${PROXY_PORT}/tcp"
    fi
else
    log_info "UFW not active — no firewall changes made."
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║              Installation Complete ✔                 ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}  Add this proxy in Zabbix UI:${RESET}"
echo -e "  Administration → Proxies → Create proxy"
echo ""
echo -e "  ${BOLD}Field              Value${RESET}"
echo -e "  ─────────────────────────────────────────────────────"
echo -e "  Proxy name         ${CYAN}${PROXY_HOSTNAME}${RESET}"
echo -e "  Proxy mode         ${CYAN}Active${RESET}"

if [[ "$USE_PSK" == "true" ]]; then
    echo ""
    echo -e "  ${BOLD}Encryption tab:${RESET}"
    echo -e "  Connections to proxy    ${CYAN}PSK${RESET}"
    echo -e "  Connections from proxy  ${CYAN}PSK${RESET}"
    echo -e "  PSK identity            ${CYAN}${PSK_IDENTITY}${RESET}"
    echo -e "  PSK value               ${CYAN}${PSK_VALUE}${RESET}"
    echo ""
    echo -e "  ${YELLOW}⚠  Save the PSK value — it cannot be recovered later.${RESET}"
    echo -e "  ${YELLOW}   It is also stored at: ${PSK_FILE}${RESET}"
fi

echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  Status:   ${CYAN}systemctl status zabbix-proxy${RESET}"
echo -e "  Logs:     ${CYAN}tail -f ${PROXY_LOG}${RESET}"
echo -e "  Restart:  ${CYAN}systemctl restart zabbix-proxy${RESET}"
echo -e "  Config:   ${CYAN}${PROXY_CONF}${RESET}"
echo ""
