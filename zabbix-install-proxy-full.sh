#!/usr/bin/env bash
# =============================================================================
# Zabbix Proxy - Interactive Install Script (Debian)
# Supports: Debian 11 (Bullseye), Debian 12 (Bookworm)
#
# Usage:
#   chmod +x install-zabbix-proxy.sh
#   sudo ./install-zabbix-proxy.sh
# =============================================================================

set -euo pipefail

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        Zabbix Proxy - Interactive Installer          ║${RESET}"
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
    *) die "Unsupported Debian version: $VERSION_CODENAME (need bullseye or bookworm)" ;;
esac

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

# --- Proxy mode --------------------------------------------------------------
print_section "Proxy Mode"
echo -e "  ${YELLOW}Active${RESET}  — proxy dials out to the Zabbix server."
echo -e "            Recommended. No inbound firewall rule required on this server."
echo ""
echo -e "  ${YELLOW}Passive${RESET} — Zabbix server connects to this proxy."
echo -e "            Requires port ${PROXY_PORT}/tcp open inbound on this server."
echo ""
prompt_choice "Proxy mode" "Active" "Passive"
PROXY_MODE_LABEL="$REPLY"
case "$REPLY" in
    Active)  PROXY_MODE=0 ;;
    Passive) PROXY_MODE=1 ;;
esac
log_info "Selected: $PROXY_MODE_LABEL"

# --- Zabbix server -----------------------------------------------------------
print_section "Zabbix Server"
REPLY=""
prompt_value "Zabbix server IP or hostname" ""
ZABBIX_SERVER="$REPLY"

REPLY=""
prompt_value "Zabbix server port" "10051"
ZABBIX_SERVER_PORT="$REPLY"

# --- Database ----------------------------------------------------------------
print_section "Proxy Local Database"
echo -e "  The proxy buffers collected data locally before forwarding to the server."
echo ""
echo -e "  ${YELLOW}SQLite3${RESET}    — simplest, zero setup, recommended for most sites"
echo -e "  ${YELLOW}MySQL${RESET}      — use for high data volumes or if you prefer MySQL"
echo -e "  ${YELLOW}PostgreSQL${RESET} — use for high data volumes or if you prefer PostgreSQL"
echo ""
prompt_choice "Database type" "SQLite3" "MySQL" "PostgreSQL"
DB_TYPE="$REPLY"

case "$DB_TYPE" in
    SQLite3)
        PROXY_PACKAGE="zabbix-proxy-sqlite3"
        DB_SETUP_NEEDED=false
        REPLY=""
        prompt_value "SQLite database file path" "/var/lib/zabbix/zabbix_proxy.db"
        SQLITE_DB_PATH="$REPLY"
        ;;
    MySQL)
        PROXY_PACKAGE="zabbix-proxy-mysql"
        DB_SETUP_NEEDED=true
        REPLY=""; prompt_value "MySQL host" "localhost";   DB_HOST="$REPLY"
        REPLY=""; prompt_value "MySQL port" "3306";        DB_PORT="$REPLY"
        REPLY=""; prompt_value "Database name" "zabbix_proxy"; DB_NAME="$REPLY"
        REPLY=""; prompt_value "Database user" "zabbix";   DB_USER="$REPLY"
        SECRET_REPLY=""; prompt_secret "Database password"; DB_PASS="$SECRET_REPLY"
        ;;
    PostgreSQL)
        PROXY_PACKAGE="zabbix-proxy-pgsql"
        DB_SETUP_NEEDED=true
        REPLY=""; prompt_value "PostgreSQL host" "localhost"; DB_HOST="$REPLY"
        REPLY=""; prompt_value "PostgreSQL port" "5432";      DB_PORT="$REPLY"
        REPLY=""; prompt_value "Database name" "zabbix_proxy"; DB_NAME="$REPLY"
        REPLY=""; prompt_value "Database user" "zabbix";      DB_USER="$REPLY"
        SECRET_REPLY=""; prompt_secret "Database password";   DB_PASS="$SECRET_REPLY"
        ;;
esac

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

# --- Performance settings ----------------------------------------------------
print_section "Performance Settings"
echo -e "  Defaults shown are suitable for a small site (~12 agents)."
echo -e "  Increase pollers and preprocessors for larger deployments."
echo ""

REPLY=""; prompt_value "Start pollers" "3";                  START_POLLERS="$REPLY"
REPLY=""; prompt_value "Start preprocessing workers" "2";    START_PREPROCESSORS="$REPLY"
REPLY=""; prompt_value "Start HTTP pollers" "1";             START_HTTP_POLLERS="$REPLY"
REPLY=""; prompt_value "Start IPMI pollers (0 = disabled)" "0"; START_IPMI_POLLERS="$REPLY"
REPLY=""; prompt_value "Config frequency in seconds (how often proxy fetches config from server)" "300"; CONFIG_FREQUENCY="$REPLY"
REPLY=""; prompt_value "Data sender frequency in seconds (how often proxy flushes data to server)" "5";  DATA_SENDER_FREQUENCY="$REPLY"
REPLY=""; prompt_value "Local buffer in seconds (hold data if server unreachable)" "3600";               PROXY_LOCAL_BUFFER="$REPLY"

# --- Summary & confirm -------------------------------------------------------
print_section "Configuration Summary"
echo ""
echo -e "  ${BOLD}Debian:${RESET}             $VERSION_CODENAME ($OS_VER)"
echo -e "  ${BOLD}Zabbix version:${RESET}     $ZABBIX_VERSION"
echo -e "  ${BOLD}Proxy hostname:${RESET}     $PROXY_HOSTNAME"
echo -e "  ${BOLD}Proxy port:${RESET}         $PROXY_PORT"
echo -e "  ${BOLD}Mode:${RESET}               $PROXY_MODE_LABEL"
echo -e "  ${BOLD}Zabbix server:${RESET}      $ZABBIX_SERVER:$ZABBIX_SERVER_PORT"
echo -e "  ${BOLD}Database:${RESET}           $DB_TYPE"

if [[ "$DB_TYPE" == "SQLite3" ]]; then
    echo -e "  ${BOLD}SQLite file:${RESET}        $SQLITE_DB_PATH"
else
    echo -e "  ${BOLD}DB host/port:${RESET}       $DB_HOST:$DB_PORT"
    echo -e "  ${BOLD}DB name / user:${RESET}     $DB_NAME / $DB_USER"
fi

echo -e "  ${BOLD}PSK:${RESET}                $([ "$USE_PSK" == "true" ] && echo "Enabled (identity: $PSK_IDENTITY)" || echo "Disabled")"
echo ""
echo -e "  ${BOLD}Performance:${RESET}"
echo -e "    Pollers                 $START_POLLERS"
echo -e "    Preprocessing workers   $START_PREPROCESSORS"
echo -e "    HTTP pollers            $START_HTTP_POLLERS"
echo -e "    IPMI pollers            $START_IPMI_POLLERS"
echo -e "    Config frequency        ${CONFIG_FREQUENCY}s"
echo -e "    Data sender frequency   ${DATA_SENDER_FREQUENCY}s"
echo -e "    Local buffer            ${PROXY_LOCAL_BUFFER}s"
echo ""

prompt_confirm "Proceed with installation" || { echo "Aborted."; exit 0; }

# =============================================================================
# INSTALLATION
# =============================================================================

print_section "Installing Zabbix Repository"

ZABBIX_REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+debian${OS_VER}_all.deb"
ZABBIX_REPO_URL_ALT="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+debian_all.deb"

TMP_DEB=$(mktemp /tmp/zabbix-release-XXXXXX.deb)
log_info "Downloading Zabbix ${ZABBIX_VERSION} release package..."

if ! curl -fsSL "$ZABBIX_REPO_URL" -o "$TMP_DEB" 2>/dev/null; then
    log_warn "Primary URL failed, trying fallback..."
    curl -fsSL "$ZABBIX_REPO_URL_ALT" -o "$TMP_DEB" \
        || die "Could not download Zabbix release package"
fi

dpkg -i "$TMP_DEB" >/dev/null 2>&1 || true
rm -f "$TMP_DEB"
apt-get update -qq
log_ok "Repository added"

# --- Install packages --------------------------------------------------------
print_section "Installing Packages"

PACKAGES=("$PROXY_PACKAGE" "zabbix-sql-scripts")
[[ "$DB_TYPE" == "MySQL" ]]      && PACKAGES+=("default-mysql-client")
[[ "$DB_TYPE" == "PostgreSQL" ]] && PACKAGES+=("postgresql-client")

log_info "Installing: ${PACKAGES[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${PACKAGES[@]}"
log_ok "Packages installed"

# --- Database setup ----------------------------------------------------------
if [[ "$DB_SETUP_NEEDED" == "true" ]]; then
    print_section "Database Setup"

    if [[ "$DB_TYPE" == "MySQL" ]]; then
        if [[ "$DB_HOST" == "localhost" ]] && command -v mysql &>/dev/null; then
            log_info "Creating MySQL database and user..."
            mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
            log_info "Importing proxy schema..."
            zcat /usr/share/zabbix/sql-scripts/mysql/proxy.sql.gz | \
                mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
            log_ok "MySQL database configured"
        else
            log_warn "Remote MySQL — skipping automatic DB creation. Run manually on $DB_HOST:"
            echo ""
            echo -e "    ${YELLOW}CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;${RESET}"
            echo -e "    ${YELLOW}CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '<password>';${RESET}"
            echo -e "    ${YELLOW}GRANT ALL ON ${DB_NAME}.* TO '${DB_USER}'@'%';${RESET}"
            echo -e "    ${YELLOW}zcat /usr/share/zabbix/sql-scripts/mysql/proxy.sql.gz | mysql -u${DB_USER} -p ${DB_NAME}${RESET}"
            echo ""
            prompt_confirm "Continue once the database is ready" || die "Aborted"
        fi

    elif [[ "$DB_TYPE" == "PostgreSQL" ]]; then
        if [[ "$DB_HOST" == "localhost" ]] && command -v psql &>/dev/null; then
            log_info "Creating PostgreSQL database and user..."
            sudo -u postgres psql <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
  END IF;
END \$\$;
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL
            log_info "Importing proxy schema..."
            sudo -u postgres psql -d "$DB_NAME" -U "$DB_USER" \
                -f <(zcat /usr/share/zabbix/sql-scripts/postgresql/proxy.sql.gz)
            log_ok "PostgreSQL database configured"
        else
            log_warn "Remote PostgreSQL — skipping automatic DB creation. Run manually on $DB_HOST:"
            echo ""
            echo -e "    ${YELLOW}CREATE USER ${DB_USER} WITH PASSWORD '<password>';${RESET}"
            echo -e "    ${YELLOW}CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};${RESET}"
            echo -e "    ${YELLOW}zcat /usr/share/zabbix/sql-scripts/postgresql/proxy.sql.gz | psql -U ${DB_USER} ${DB_NAME}${RESET}"
            echo ""
            prompt_confirm "Continue once the database is ready" || die "Aborted"
        fi
    fi
fi

# --- SQLite directory --------------------------------------------------------
if [[ "$DB_TYPE" == "SQLite3" ]]; then
    SQLITE_DIR=$(dirname "$SQLITE_DB_PATH")
    mkdir -p "$SQLITE_DIR"
    chown zabbix:zabbix "$SQLITE_DIR"
    chmod 750 "$SQLITE_DIR"
    log_ok "SQLite directory ready: $SQLITE_DIR"
    log_info "Database file will be created automatically on first start"
fi

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

# Database block
if [[ "$DB_TYPE" == "SQLite3" ]]; then
    DB_BLOCK="DBName=${SQLITE_DB_PATH}"
else
    DB_BLOCK="DBHost=${DB_HOST}
DBPort=${DB_PORT}
DBName=${DB_NAME}
DBUser=${DB_USER}
DBPassword=${DB_PASS}"
fi

# PSK block
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
# =============================================================================

### Identity
Hostname=${PROXY_HOSTNAME}

### Mode (0 = Active, 1 = Passive)
ProxyMode=${PROXY_MODE}

### Zabbix Server
Server=${ZABBIX_SERVER}
ServerPort=${ZABBIX_SERVER_PORT}

### Listen
ListenIP=0.0.0.0
ListenPort=${PROXY_PORT}

### Logging
LogFile=${PROXY_LOG}
LogFileSize=20
DebugLevel=3
PidFile=${PROXY_PID}

### Database
${DB_BLOCK}

### Encryption
${PSK_BLOCK}

### Pollers
StartPollers=${START_POLLERS}
StartIPMIPollers=${START_IPMI_POLLERS}
StartPreprocessingWorkers=${START_PREPROCESSORS}
StartHTTPPollers=${START_HTTP_POLLERS}
StartJavaPollers=0

### Frequency
ProxyConfigFrequency=${CONFIG_FREQUENCY}
ProxyDataSenderFrequency=${DATA_SENDER_FREQUENCY}

### Buffering
ProxyLocalBuffer=${PROXY_LOCAL_BUFFER}
ProxyOfflineBuffer=${PROXY_LOCAL_BUFFER}

### Timeouts
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
    log_info "UFW is active."
    if [[ "$PROXY_MODE" -eq 0 ]]; then
        log_info "Active mode — proxy dials OUT, no inbound rule needed for normal operation."
        if prompt_confirm "Open port ${PROXY_PORT}/tcp anyway (for passive checks or status queries)" "n"; then
            ufw allow "${PROXY_PORT}/tcp" comment "Zabbix Proxy" >/dev/null
            log_ok "UFW rule added for port ${PROXY_PORT}/tcp"
        fi
    else
        log_info "Passive mode — server will connect inbound to this proxy."
        if prompt_confirm "Open port ${PROXY_PORT}/tcp (required for passive mode)"; then
            ufw allow "${PROXY_PORT}/tcp" comment "Zabbix Proxy" >/dev/null
            log_ok "UFW rule added for port ${PROXY_PORT}/tcp"
        else
            log_warn "Port not opened — passive mode will not work until this is done manually"
        fi
    fi
else
    log_info "UFW not active — configure your firewall manually if needed (port: ${PROXY_PORT}/tcp)"
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
echo -e "  Proxy mode         ${CYAN}${PROXY_MODE_LABEL}${RESET}"
if [[ "$PROXY_MODE" -eq 1 ]]; then
    echo -e "  Proxy address      ${CYAN}$(hostname -I | awk '{print $1}'):${PROXY_PORT}${RESET}"
fi

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
