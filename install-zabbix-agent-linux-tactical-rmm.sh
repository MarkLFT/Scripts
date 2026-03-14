#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Zabbix Agent 2 Install / Update Script (Linux)
# Supports: Debian 11/12, Ubuntu 20.04/22.04/24.04
#
# Script Arguments (set in TacticalRMM):
#   $1 = {{site.ZabbixProxy}}      e.g. 10.10.1.5
#   $2 = {{site.ZabbixServer}}     e.g. 10.10.0.10
#   $3 = {{global.DiscordWebhook}} e.g. https://discord.com/api/webhooks/...
#   $4 = {{global.ZabbixVersion}}  e.g. 7.4
# =============================================================================

set -eo pipefail

# --- Arguments ---------------------------------------------------------------
# TacticalRMM wraps shell script arguments in single quotes — strip them
ZABBIX_PROXY=$(echo "${1:-}"    | tr -d "'")
ZABBIX_SERVER=$(echo "${2:-}"   | tr -d "'")
DISCORD_WEBHOOK=$(echo "${3:-}" | tr -d "'")
ZABBIX_VERSION=$(echo "${4:-}"  | tr -d "'")
AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
AGENT_CONF_D="/etc/zabbix/zabbix_agent2.d"

# --- Debug (temporary) -------------------------------------------------------
echo "DEBUG $1 hex: $(printf '%s' "${1:-}" | xxd | head -1)"
echo "DEBUG PROXY after strip: |${ZABBIX_PROXY}|"
echo "DEBUG SERVER after strip: |${ZABBIX_SERVER}|"

# --- Input validation --------------------------------------------------------
# SECURITY: Validate all arguments before use in URLs, config files, or commands.

if [[ -z "$ZABBIX_PROXY" || -z "$ZABBIX_SERVER" ]]; then
    echo "ERROR: ZabbixProxy and ZabbixServer are required."
    exit 1
fi

if [[ -z "$ZABBIX_VERSION" ]]; then
    echo "ERROR: ZabbixVersion global variable is not set."
    exit 1
fi

# Proxy and server must be a valid IPv4, IPv6, or hostname (no spaces, quotes, semicolons etc.)
ADDR_PATTERN='^[a-zA-Z0-9._\-]+$'
if [[ ! "$ZABBIX_PROXY" =~ $ADDR_PATTERN ]]; then
    echo "ERROR: ZabbixProxy contains invalid characters: $ZABBIX_PROXY"
    exit 1
fi
if [[ ! "$ZABBIX_SERVER" =~ $ADDR_PATTERN ]]; then
    echo "ERROR: ZabbixServer contains invalid characters: $ZABBIX_SERVER"
    exit 1
fi

# Version must be x.y format only
if [[ ! "$ZABBIX_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: ZabbixVersion must be in x.y format (e.g. 7.4), got: $ZABBIX_VERSION"
    exit 1
fi

# --- Helpers -----------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }

# SECURITY: Escape a string for safe inclusion in a JSON value.
# Escapes backslash, double-quote, and control characters.
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

    # SECURITY: Escape all user-controlled values before embedding in JSON.
    local safe_title safe_desc
    safe_title=$(json_escape "$title")
    safe_desc=$(json_escape "$description")

    local payload
    payload=$(printf '{
  "embeds": [{
    "title": "%s",
    "description": "%s",
    "color": %d,
    "footer": { "text": "TacticalRMM - Zabbix Agent" },
    "timestamp": "%s"
  }]
}' "$safe_title" "$safe_desc" "$color" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

    curl -s -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK" >/dev/null 2>&1 \
        || warn "Discord notification failed"
}

service_active()    { systemctl is-active --quiet "$1" 2>/dev/null; }
package_installed() { dpkg -s "$1" &>/dev/null; }

# --- Gather system info ------------------------------------------------------
HOSTNAME=$(hostname -f)
IP_ADDRESS=$(hostname -I | awk '{print $1}')
OS_ID=$(. /etc/os-release && echo "$ID")
OS_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
OS_VERSION=$(. /etc/os-release && echo "$VERSION_ID")

log "Host:    $HOSTNAME ($IP_ADDRESS)"
log "OS:      $OS_ID $OS_VERSION ($OS_CODENAME)"
log "Proxy:   $ZABBIX_PROXY"
log "Target:  Zabbix Agent 2 $ZABBIX_VERSION"

case "$OS_ID" in
    ubuntu) REPO_OS="ubuntu" ;;
    debian) REPO_OS="debian" ;;
    *)
        send_discord "❌ Zabbix Install Failed" \
            "**Host:** \`$HOSTNAME\`\n**IP:** \`$IP_ADDRESS\`\n**Reason:** Unsupported OS: $OS_ID" 15158332
        echo "ERROR: Unsupported OS: $OS_ID"; exit 1 ;;
esac

# --- Check if already on the target version ----------------------------------
PREV_VERSION=""
ACTION=""

if package_installed zabbix-agent2; then
    PREV_VERSION=$(dpkg -s zabbix-agent2 | grep '^Version:' | awk '{print $2}')
    log "Installed version: $PREV_VERSION"

    if [[ "$PREV_VERSION" == ${ZABBIX_VERSION}* ]]; then
        log "Already on version $ZABBIX_VERSION — nothing to do."
        exit 0
    fi

    ACTION="Updated"
    log "Upgrade needed: $PREV_VERSION -> $ZABBIX_VERSION"
else
    ACTION="Installed"
    log "Agent not installed — performing fresh install."
fi

# --- Add Zabbix repository ---------------------------------------------------
# Official format: zabbix-release_latest+ubuntu22.04_all.deb
# Note: no version number in the filename, full OS version (e.g. 22.04 not 22)
ZABBIX_RELEASE_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/${REPO_OS}/pool/main/z/zabbix-release/zabbix-release_latest+${REPO_OS}${OS_VERSION}_all.deb"
# Fallback: versioned filename e.g. zabbix-release_7.4-0.1+ubuntu22.04_all.deb
ZABBIX_RELEASE_URL_ALT="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/${REPO_OS}/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-0.1+${REPO_OS}${OS_VERSION}_all.deb"

log "Adding Zabbix ${ZABBIX_VERSION} repository..."
TMP_DEB=$(mktemp /tmp/zabbix-release-XXXXXX.deb)

# Ensure temp file is cleaned up on any exit
trap 'rm -f "$TMP_DEB"' EXIT

if ! curl -fsSL "$ZABBIX_RELEASE_URL" -o "$TMP_DEB" 2>/dev/null; then
    warn "Primary URL failed, trying fallback..."
    curl -fsSL "$ZABBIX_RELEASE_URL_ALT" -o "$TMP_DEB" || {
        send_discord "❌ Zabbix Install Failed" \
            "**Host:** \`$HOSTNAME\`\n**IP:** \`$IP_ADDRESS\`\n**Reason:** Could not download release package" 15158332
        echo "ERROR: Could not download Zabbix release package"; exit 1
    }
fi

# SECURITY: Previously used '|| true' which silently swallowed dpkg errors.
# Now fail explicitly if the repo package cannot be installed.
if ! dpkg -i "$TMP_DEB" >/dev/null 2>&1; then
    warn "dpkg -i reported an error — attempting to fix and continue..."
    apt-get install -f -y -qq || {
        send_discord "❌ Zabbix Install Failed" \
            "**Host:** \`$HOSTNAME\`\n**IP:** \`$IP_ADDRESS\`\n**Reason:** Failed to install Zabbix release package" 15158332
        echo "ERROR: Failed to install Zabbix release package"; exit 1
    }
fi

apt-get update -qq

log "Installing zabbix-agent2..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-agent2 zabbix-agent2-plugin-*

NEW_VERSION=$(dpkg -s zabbix-agent2 | grep '^Version:' | awk '{print $2}')
log "Agent version now: $NEW_VERSION"

# --- Write configuration -----------------------------------------------------
log "Writing $AGENT_CONF ..."
mkdir -p "$AGENT_CONF_D"

cat > "$AGENT_CONF" <<EOF
# Zabbix Agent 2 Configuration
# Managed by TacticalRMM - do not edit manually

Hostname=${HOSTNAME}
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
PidFile=/run/zabbix/zabbix_agent2.pid

# Agent accepts checks from the proxy only
Server=${ZABBIX_PROXY}
ServerActive=${ZABBIX_PROXY}

# SECURITY: system.run (remote command execution) is disabled by default in
# Zabbix Agent 2 and is intentionally not enabled here. Do not add
# AllowKey=system.run[*] unless you have a specific, audited requirement.
DenyKey=system.run[*]

Timeout=10
RefreshActiveChecks=120
BufferSend=5
BufferSize=200

Include=${AGENT_CONF_D}/*.conf
EOF

# Set restrictive permissions on the main config
chown root:zabbix "$AGENT_CONF"
chmod 640 "$AGENT_CONF"

# --- Detect services & write plugin configs ----------------------------------
DETECTED_SERVICES=()
log "Scanning for monitorable services..."

if service_active mssql-server || systemctl list-units --type=service 2>/dev/null | grep -q mssql; then
    log "  [FOUND] Microsoft SQL Server"; DETECTED_SERVICES+=("Microsoft SQL Server")
    cat > "${AGENT_CONF_D}/mssql.conf" <<'EOF'
# Microsoft SQL Server - Zabbix Agent 2 Plugin
# CREATE LOGIN zabbix WITH PASSWORD = 'StrongPassword!';
# GRANT VIEW SERVER STATE TO zabbix;
# GRANT VIEW ANY DEFINITION TO zabbix;

Plugins.MSSQL.Sessions.local.Uri=sqlserver://localhost:1433
Plugins.MSSQL.Sessions.local.User=zabbix
Plugins.MSSQL.Sessions.local.Password=CHANGE_ME
Plugins.MSSQL.Sessions.local.TLSConnect=disable
EOF
    warn "  SQL Server config written — update credentials in ${AGENT_CONF_D}/mssql.conf"
fi

if service_active mysql || service_active mariadb; then
    SVC_NAME="MySQL"; service_active mariadb && SVC_NAME="MariaDB"
    log "  [FOUND] $SVC_NAME"; DETECTED_SERVICES+=("$SVC_NAME")
    cat > "${AGENT_CONF_D}/mysql.conf" <<'EOF'
# MySQL/MariaDB - Zabbix Agent 2 Plugin
# CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'StrongPassword!';
# GRANT REPLICATION CLIENT, PROCESS, SHOW DATABASES, SHOW VIEW ON *.* TO 'zabbix'@'localhost';

Plugins.Mysql.Sessions.local.Uri=tcp://localhost:3306
Plugins.Mysql.Sessions.local.User=zabbix
Plugins.Mysql.Sessions.local.Password=CHANGE_ME
EOF
    warn "  MySQL config written — update credentials in ${AGENT_CONF_D}/mysql.conf"
fi

if service_active postgresql; then
    log "  [FOUND] PostgreSQL"; DETECTED_SERVICES+=("PostgreSQL")
    cat > "${AGENT_CONF_D}/postgresql.conf" <<'EOF'
# PostgreSQL - Zabbix Agent 2 Plugin
# CREATE USER zabbix WITH PASSWORD 'StrongPassword!';
# GRANT pg_monitor TO zabbix;

Plugins.PostgreSQL.Sessions.local.Uri=tcp://localhost:5432
Plugins.PostgreSQL.Sessions.local.User=zabbix
Plugins.PostgreSQL.Sessions.local.Password=CHANGE_ME
Plugins.PostgreSQL.Sessions.local.Database=postgres
EOF
    warn "  PostgreSQL config written — update credentials in ${AGENT_CONF_D}/postgresql.conf"
fi

if service_active nginx; then
    log "  [FOUND] Nginx"; DETECTED_SERVICES+=("Nginx")
    cat > "${AGENT_CONF_D}/nginx.conf" <<'EOF'
# Nginx - requires stub_status in nginx config:
#   location /nginx_status { stub_status on; allow 127.0.0.1; deny all; }
Plugins.Nginx.Sessions.local.Uri=http://localhost/nginx_status
EOF
fi

if service_active apache2; then
    log "  [FOUND] Apache2"; DETECTED_SERVICES+=("Apache2")
    cat > "${AGENT_CONF_D}/apache.conf" <<'EOF'
# Apache - requires mod_status (a2enmod status)
#   <Location /server-status>
#       SetHandler server-status
#       Require local
#   </Location>
Plugins.Apache.Sessions.local.Uri=http://localhost/server-status?auto
EOF
fi

if command -v docker &>/dev/null && service_active docker; then
    log "  [FOUND] Docker"; DETECTED_SERVICES+=("Docker")
    echo "Plugins.Docker.Endpoint=unix:///var/run/docker.sock" > "${AGENT_CONF_D}/docker.conf"
    usermod -aG docker zabbix 2>/dev/null || warn "Could not add zabbix to docker group"
fi

if service_active redis-server || service_active redis; then
    log "  [FOUND] Redis"; DETECTED_SERVICES+=("Redis")
    echo "Plugins.Redis.Sessions.local.Uri=tcp://localhost:6379" > "${AGENT_CONF_D}/redis.conf"
fi

# SECURITY: Restrict all plugin configs to root:zabbix, not world-readable.
# DB credential files in this directory must not be readable by other users.
chown -R root:zabbix "$AGENT_CONF_D" 2>/dev/null || true
chmod 750 "$AGENT_CONF_D"
chmod 640 "${AGENT_CONF_D}"/*.conf 2>/dev/null || true

# --- Enable & restart agent --------------------------------------------------
log "Restarting zabbix-agent2..."
systemctl enable zabbix-agent2 --quiet
systemctl restart zabbix-agent2
sleep 2

if ! systemctl is-active --quiet zabbix-agent2; then
    send_discord "❌ Zabbix Agent Failed to Start" \
        "**Host:** \`$HOSTNAME\`\n**IP:** \`$IP_ADDRESS\`\n**Version:** \`$NEW_VERSION\`\n**Proxy:** \`$ZABBIX_PROXY\`" 15158332
    echo "ERROR: zabbix-agent2 failed to start"; exit 1
fi

# --- Send Discord notification -----------------------------------------------
SERVICES_MSG="None detected"
if [[ ${#DETECTED_SERVICES[@]} -gt 0 ]]; then
    SERVICES_MSG=$(printf '%s, ' "${DETECTED_SERVICES[@]}"); SERVICES_MSG="${SERVICES_MSG%, }"
fi

if [[ "$ACTION" == "Updated" ]]; then
    VERSION_MSG="**Version:** \`$PREV_VERSION\` -> \`$NEW_VERSION\`"; COLOR=3447003
else
    VERSION_MSG="**Version:** \`$NEW_VERSION\`"; COLOR=3066993
fi

CRED_WARNING=""
[[ ${#DETECTED_SERVICES[@]} -gt 0 ]] && \
    CRED_WARNING="\n⚠️ Action Required: Update DB credentials in ${AGENT_CONF_D}/"

send_discord "✅ Zabbix Agent ${ACTION}" \
    "**Host:** \`$HOSTNAME\`\n**IP:** \`$IP_ADDRESS\`\n${VERSION_MSG}\n**Proxy:** \`$ZABBIX_PROXY\`\n**Services Detected:** ${SERVICES_MSG}${CRED_WARNING}" \
    "$COLOR"

log "Done. Action: $ACTION | Services: $SERVICES_MSG"
exit 0
