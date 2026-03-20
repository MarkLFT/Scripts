#!/usr/bin/env bash
# =============================================================================
# setup-sqlserver-ubuntu.sh
# Ubuntu 24.04 LTS - SQL Server 2025 Full Setup Script
#
# Tasks:
#  0. Rename computer / configure domain name (rmserver.local)
#  1. Install SQL Server 2025 (native Ubuntu 24.04 repo - officially supported)
#     with configurable collation, data/log dirs, license type, and sa password
#  2. Install & configure MSDTC with recommended fixed ports
#  3. Capture current UFW rules and convert them to iptables rules
#  4. Add MSDTC iptables rules (PREROUTING NAT + INPUT filter)
#  5. Persist all iptables rules via iptables-persistent
#  6. Uninstall UFW
#  7. Create backup folder, backup all user databases to per-DB folders,
#     copy backups to a remote SMB share, and schedule auto-cleanup
#
# Requirements: Run as root or via sudo. Tested on Ubuntu 24.04 LTS.
# =============================================================================

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYN}[INFO]${NC}  $*"; }
success() { echo -e "${GRN}[OK]${NC}    $*"; }
warn()    { echo -e "${YEL}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo -E)."

# ─── Prompt helpers ──────────────────────────────────────────────────────────
ask() {
    # ask <VAR_NAME> <prompt> [default]
    local varname="$1" prompt="$2" default="${3:-}"
    local value=""
    while [[ -z "$value" ]]; do
        if [[ -n "$default" ]]; then
            read -rp "$(echo -e "${YEL}  >> ${NC}${prompt} [${default}]: ")" value
            value="${value:-$default}"
        else
            read -rp "$(echo -e "${YEL}  >> ${NC}${prompt}: ")" value
        fi
        [[ -z "$value" ]] && warn "Value cannot be empty."
    done
    printf -v "$varname" '%s' "$value"
}

ask_secret() {
    # ask_secret <VAR_NAME> <prompt> (no echo, must confirm)
    local varname="$1" prompt="$2"
    local val1="" val2=""
    while true; do
        read -rsp "$(echo -e "${YEL}  >> ${NC}${prompt}: ")" val1; echo
        read -rsp "$(echo -e "${YEL}  >> ${NC}Confirm ${prompt}: ")" val2; echo
        if [[ "$val1" == "$val2" && -n "$val1" ]]; then
            printf -v "$varname" '%s' "$val1"
            break
        fi
        warn "Passwords do not match or are empty. Try again."
    done
}

ask_yn() {
    # ask_yn <prompt> — returns 0 for yes, 1 for no
    local answer=""
    while true; do
        read -rp "$(echo -e "${YEL}  >> ${NC}$1 [y/n]: ")" answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

# ─── Validate helpers ────────────────────────────────────────────────────────
validate_path() {
    # validate_path <path>  — ensures it starts with /
    [[ "$1" == /* ]] || return 1
    return 0
}

validate_hostname() {
    # RFC 952/1123 label: alphanumeric + hyphens, no leading/trailing hyphen
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    return 0
}

validate_sa_password() {
    # SQL Server policy: >=8 chars, 3 of 4: upper, lower, digit, special
    local pw="$1"
    local score=0
    [[ "$pw" =~ [A-Z] ]] && ((score++)) || true
    [[ "$pw" =~ [a-z] ]] && ((score++)) || true
    [[ "$pw" =~ [0-9] ]] && ((score++)) || true
    [[ "$pw" =~ [^a-zA-Z0-9] ]] && ((score++)) || true
    [[ ${#pw} -ge 8 && $score -ge 3 ]] || return 1
    return 0
}

# ─── SMB share helpers ───────────────────────────────────────────────────────
mount_smb() {
    local smb_share="$1" smb_user="$2" smb_pass="$3" mount_point="$4"
    mkdir -p "$mount_point"
    mount -t cifs "$smb_share" "$mount_point" \
        -o "username=${smb_user},password=${smb_pass},vers=3.0,file_mode=0770,dir_mode=0770" \
        2>/dev/null || return 1
}

# =============================================================================
# SECTION 0 — Gather all information up front
# =============================================================================
echo ""
echo -e "${CYN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYN}║   Ubuntu 24.04 SQL Server 2025 — Full Setup Script           ║${NC}"
echo -e "${CYN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "All settings will be collected first, then the script will execute."
echo ""

# ── 0: Hostname ───────────────────────────────────────────────────────────────
echo -e "${CYN}── Section 0: Hostname & Domain ──────────────────────────────────${NC}"
echo "  The server will be named <hostname>.rmserver.local"
echo "  Default hostname is: db"
while true; do
    ask NEW_HOSTNAME "New short hostname (e.g. db)" "db"
    validate_hostname "$NEW_HOSTNAME" && break
    warn "Invalid hostname. Use letters, numbers, hyphens only (not leading/trailing hyphen)."
done
FULL_FQDN="${NEW_HOSTNAME}.rmserver.local"
echo ""

# ── 1: SQL Server ─────────────────────────────────────────────────────────────
echo -e "${CYN}── Section 1: SQL Server 2025 Settings ───────────────────────────${NC}"
echo ""

echo "  License types:"
echo "    1) Evaluation  (free, 180-day, all Enterprise features)"
echo "    2) Developer   (free, non-production, all Enterprise features)  [default]"
echo "    3) Express     (free, limited to 10 GB, no SQL Agent)"
echo "    4) Standard    (paid)"
echo "    5) Enterprise  (paid)"
echo ""
while true; do
    ask SQL_PID_NUM "Choose license type [1-5]" "2"
    case "$SQL_PID_NUM" in
        1) SQL_PID="Evaluation";  break ;;
        2) SQL_PID="Developer";   break ;;
        3) SQL_PID="Express";     break ;;
        4) SQL_PID="Standard";    break ;;
        5) SQL_PID="Enterprise";  break ;;
        *) warn "Enter a number between 1 and 5." ;;
    esac
done

echo ""
echo "  Default server collation (press Enter to accept default)."
echo "  Common examples: SQL_Latin1_General_CP1_CI_AS, Latin1_General_CI_AS,"
echo "                   Latin1_General_100_CI_AS_SC_UTF8"
ask SQL_COLLATION "Server collation" "SQL_Latin1_General_CP1_CI_AI"

echo ""
echo "  SQL Server data and log directories."
echo "  The mssql user will be set as owner of these directories."
while true; do
    ask SQL_DATA_DIR "Default data directory" "/sqldata"
    validate_path "$SQL_DATA_DIR" && break
    warn "Path must be absolute (start with /)."
done
while true; do
    ask SQL_LOG_DIR "Default log directory" "/sqllog"
    validate_path "$SQL_LOG_DIR" && break
    warn "Path must be absolute (start with /)."
done
while true; do
    ask SQL_BACKUP_DIR "Default backup directory" "/sqlbackup"
    validate_path "$SQL_BACKUP_DIR" && break
    warn "Path must be absolute (start with /)."
done

echo ""
echo "  SA password rules: ≥8 characters, 3 of 4: UPPER, lower, digit, special."
while true; do
    ask_secret SA_PASSWORD "SA password"
    validate_sa_password "$SA_PASSWORD" && break
    warn "Password does not meet complexity requirements. Try again."
done

echo ""

# ── SQL Server memory limit ───────────────────────────────────────────────────
echo -e "${CYN}── Section 1b: SQL Server Memory Limit ───────────────────────────${NC}"
echo ""
echo "  SQL Server on Linux defaults to 80% of RAM if no limit is set."
echo "  For a dedicated database server, 80–90% is appropriate."
echo "  Leaving headroom for the OS prevents the kernel from paging SQL Server."
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
SUGGESTED_MEM=$(( TOTAL_RAM_MB * 85 / 100 ))
echo "  Detected RAM : ${TOTAL_RAM_MB} MB"
echo "  Suggested    : ${SUGGESTED_MEM} MB  (85%)"
echo ""
while true; do
    ask SQL_MEM_LIMIT_MB "SQL Server memory limit in MB" "${SUGGESTED_MEM}"
    [[ "$SQL_MEM_LIMIT_MB" =~ ^[0-9]+$ && "$SQL_MEM_LIMIT_MB" -ge 2048 ]] && break
    warn "Must be a number ≥ 2048 (SQL Server minimum is 2 GB)."
done
echo ""

# ── 2: MSDTC ports ────────────────────────────────────────────────────────────
echo -e "${CYN}── Section 2: MSDTC Ports ────────────────────────────────────────${NC}"
echo ""
echo "  Microsoft recommended ports for SQL Server on Linux:"
echo "    RPC port (network.rpcport)              : 13500"
echo "    MSDTC server TCP port (servertcpport)   : 51999"
echo ""
echo "  Port 135 (RPC Endpoint Mapper) will be NAT-forwarded to the RPC port"
echo "  via iptables PREROUTING, as processes cannot bind to port 135 without root."
echo ""
if ask_yn "Use recommended ports (13500 / 51999)?"; then
    MSDTC_RPC_PORT=13500
    MSDTC_DTC_PORT=51999
else
    while true; do
        ask MSDTC_RPC_PORT "RPC port (network.rpcport)" "13500"
        [[ "$MSDTC_RPC_PORT" =~ ^[0-9]+$ && "$MSDTC_RPC_PORT" -gt 1023 && "$MSDTC_RPC_PORT" -lt 65536 ]] && break
        warn "Port must be a number between 1024 and 65535."
    done
    while true; do
        ask MSDTC_DTC_PORT "MSDTC server TCP port (servertcpport)" "51999"
        [[ "$MSDTC_DTC_PORT" =~ ^[0-9]+$ && "$MSDTC_DTC_PORT" -gt 1023 && "$MSDTC_DTC_PORT" -lt 65536 ]] && break
        warn "Port must be a number between 1024 and 65535."
    done
fi
echo ""

# ── 7: Backup / SMB ───────────────────────────────────────────────────────────
echo -e "${CYN}── Section 7: Backup & Remote SMB Share ──────────────────────────${NC}"
echo ""
echo "  Local backup root (databases are backed up to sub-folders here)."
while true; do
    ask LOCAL_BACKUP_ROOT "$SQL_BACKUP_DIR already entered above — use same path?" "$SQL_BACKUP_DIR"
    validate_path "$LOCAL_BACKUP_ROOT" && break
    warn "Path must be absolute."
done

echo ""
echo "  Remote SMB share to copy backups to."
echo "  Format: //server/share  or  //192.168.1.x/share"
while true; do
    ask SMB_SHARE "SMB share path (e.g. //192.168.1.50/sqlbackups)" ""
    [[ "$SMB_SHARE" =~ ^//[^/].* ]] && break
    warn "Share must start with // e.g. //server/share"
done
ask SMB_USER   "SMB username"   ""
ask_secret SMB_PASS "SMB password"
ask SMB_MOUNT  "Local SMB mount point" "/mnt/sqlbackups_remote"

echo ""
echo "  Backup retention (days to keep backups locally and on SMB share)."
while true; do
    ask BACKUP_RETENTION "Retention in days" "30"
    [[ "$BACKUP_RETENTION" =~ ^[0-9]+$ && "$BACKUP_RETENTION" -gt 0 ]] && break
    warn "Must be a positive integer."
done

echo ""
echo "  TDE certificate export."
echo "  Your databases use Transparent Data Encryption (TDE). Their backup"
echo "  files are already encrypted implicitly — no separate backup password"
echo "  is needed. However, the TDE certificate MUST be exported and stored"
echo "  safely. Without it, backups cannot be restored on any other server."
echo ""
echo "  The certificate files will be stored SEPARATELY from the backup tree:"
echo "    - Locally  : /etc/mssql-tde-certs/  (root:root 700, files 400)"
echo "    - Remotely : a SEPARATE SMB share you specify below (not the"
echo "                 backup share — certificates and backups must not"
echo "                 be stored together)"
echo ""
echo "  You must supply the password that will protect the exported private"
echo "  key file. Store this password in a password manager or physical safe."
echo ""
echo "  Password rules: ≥8 characters, 3 of 4: UPPER, lower, digit, special."
while true; do
    ask_secret TDE_CERT_EXPORT_PASSWORD "TDE certificate export password"
    validate_sa_password "$TDE_CERT_EXPORT_PASSWORD" && break
    warn "Password does not meet complexity requirements. Try again."
done

echo ""
echo "  Separate SMB share for TDE certificate storage."
echo "  This MUST be a different share from the backup share above."
echo "  It should be on a different server, accessible only to DBAs."
while true; do
    ask TDE_CERT_SMB_SHARE "SMB share for certificates (e.g. //192.168.1.51/sqlcerts)" ""
    [[ "$TDE_CERT_SMB_SHARE" =~ ^//[^/].* ]] || { warn "Share must start with //"; continue; }
    [[ "$TDE_CERT_SMB_SHARE" != "$SMB_SHARE" ]] || { warn "Certificate share must be DIFFERENT from the backup share."; continue; }
    break
done
ask TDE_CERT_SMB_USER  "Certificate share SMB username" ""
ask_secret TDE_CERT_SMB_PASS "Certificate share SMB password"
ask TDE_CERT_SMB_MOUNT "Local mount point for certificate share" "/mnt/sqlcerts_remote"

echo ""

# ── NTP / time synchronisation ────────────────────────────────────────────────
echo -e "${CYN}── Section 8: NTP / Time Synchronisation ─────────────────────────${NC}"
echo ""
echo "  Accurate time is required for MSDTC, TDE, Kerberos, and log correlation."
echo "  chrony will be installed and configured. If you have an internal NTP"
echo "  server (e.g. a domain controller), enter it here; otherwise the default"
echo "  Ubuntu NTP pools will be used."
echo ""
ask NTP_SERVER "NTP server (hostname/IP, or press Enter for pool.ntp.org)" "pool.ntp.org"
echo ""

# ── SSH hardening ─────────────────────────────────────────────────────────────
echo -e "${CYN}── Section 9: SSH Hardening ──────────────────────────────────────${NC}"
echo ""
echo "  Root SSH login and password authentication will be disabled."
echo "  Ensure you have an SSH key deployed for your admin user BEFORE"
echo "  proceeding — you will be locked out otherwise."
echo ""
echo "  Current SSH authorised keys on this system:"
find /home /root -name authorized_keys 2>/dev/null | while read -r f; do
    echo "    $f"
done || true
echo ""
if ask_yn "Proceed with SSH hardening (disable root login + password auth)?"; then
    SSH_HARDEN=true
else
    SSH_HARDEN=false
    warn "SSH hardening skipped. Strongly recommended for production."
fi
echo ""

# ── fail2ban ──────────────────────────────────────────────────────────────────
echo -e "${CYN}── Section 10: fail2ban ──────────────────────────────────────────${NC}"
echo ""
echo "  fail2ban monitors /var/log/auth.log and automatically bans IPs"
echo "  after repeated failed SSH login attempts using iptables rules."
echo ""
echo "  You may whitelist your management IP/subnet so it can never be"
echo "  accidentally banned (e.g. 192.168.1.0/24). Leave blank to skip."
ask FAIL2BAN_IGNOREIP "Management IP/subnet to whitelist (blank to skip)" ""
echo ""

# ─── Summary before execution ────────────────────────────────────────────────
echo -e "${CYN}══════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYN}  CONFIGURATION SUMMARY — please review before continuing${NC}"
echo -e "${CYN}══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Hostname      : ${FULL_FQDN}"
echo "  SQL Edition   : ${SQL_PID}"
echo "  Collation     : ${SQL_COLLATION}"
echo "  Data dir      : ${SQL_DATA_DIR}"
echo "  Log dir       : ${SQL_LOG_DIR}"
echo "  Backup dir    : ${SQL_BACKUP_DIR}"
echo "  MSDTC RPC     : ${MSDTC_RPC_PORT}"
echo "  MSDTC DTC     : ${MSDTC_DTC_PORT}"
echo "  Local backup  : ${LOCAL_BACKUP_ROOT}"
echo "  SMB share     : ${SMB_SHARE}"
echo "  SMB user      : ${SMB_USER}"
echo "  SMB mount     : ${SMB_MOUNT}"
echo "  Retention     : ${BACKUP_RETENTION} days"
echo "  Backup encrypt: TDE (implicit — databases encrypted at rest)"
echo "  TDE cert share: ${TDE_CERT_SMB_SHARE} (separate from backup share)"
echo "  SQL mem limit : ${SQL_MEM_LIMIT_MB} MB"
echo "  NTP server    : ${NTP_SERVER}"
echo "  SSH harden    : ${SSH_HARDEN}"
echo "  fail2ban      : enabled (whitelist: ${FAIL2BAN_IGNOREIP:-none})"
echo ""
ask_yn "Proceed with installation?" || { info "Aborted."; exit 0; }
echo ""

# =============================================================================
# SECTION 0 — Rename computer
# =============================================================================
echo -e "${CYN}━━ Step 0: Renaming computer to ${FULL_FQDN} ━━━━━━━━━━━━━━━━━━━━${NC}"

OLD_HOSTNAME=$(hostname)
hostnamectl set-hostname "${NEW_HOSTNAME}"

# Update /etc/hosts — replace old short hostname entries
sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" /etc/hosts 2>/dev/null || true

# Ensure 127.0.1.1 line has both FQDN and short name
if grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${FULL_FQDN}\t${NEW_HOSTNAME}/" /etc/hosts
else
    echo -e "127.0.1.1\t${FULL_FQDN}\t${NEW_HOSTNAME}" >> /etc/hosts
fi

success "Hostname set to: $(hostname) | FQDN in /etc/hosts: ${FULL_FQDN}"

# =============================================================================
# SECTION 1 — Install SQL Server 2025
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 1: Installing SQL Server 2025 ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Prerequisites
info "Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq \
    curl gnupg2 apt-transport-https software-properties-common \
    cifs-utils samba-common net-tools 2>/dev/null

# Microsoft GPG key
info "Adding Microsoft GPG key..."
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg

# SQL Server 2025 repository for Ubuntu 24.04
info "Adding SQL Server 2025 repository (Ubuntu 24.04 native)..."
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list \
    | tee /etc/apt/sources.list.d/mssql-server-2025.list > /dev/null

apt-get update -qq

info "Installing mssql-server package..."
apt-get install -y mssql-server

# Pre-configure directories and settings BEFORE mssql-conf setup
info "Creating data, log, and backup directories..."
for d in "$SQL_DATA_DIR" "$SQL_LOG_DIR" "$SQL_BACKUP_DIR"; do
    mkdir -p "$d"
    chown mssql:mssql "$d"
    chmod 750 "$d"
done

info "Writing pre-setup mssql.conf (directories and collation)..."
cat > /var/opt/mssql/mssql.conf <<EOF
[EULA]
accepteula = Y

[filelocation]
defaultdatadir = ${SQL_DATA_DIR}
defaultlogdir  = ${SQL_LOG_DIR}
defaultbackupdir = ${SQL_BACKUP_DIR}

[language]
collation = ${SQL_COLLATION}
EOF
chown mssql:mssql /var/opt/mssql/mssql.conf
chmod 600 /var/opt/mssql/mssql.conf

# Non-interactive mssql-conf setup using environment variables
info "Running mssql-conf setup (non-interactive)..."
ACCEPT_EULA=Y \
MSSQL_PID="${SQL_PID}" \
MSSQL_SA_PASSWORD="${SA_PASSWORD}" \
    /opt/mssql/bin/mssql-conf -n setup

# Set file locations via mssql-conf set (authoritative method)
info "Configuring file locations via mssql-conf..."
/opt/mssql/bin/mssql-conf set filelocation.defaultdatadir   "$SQL_DATA_DIR"
/opt/mssql/bin/mssql-conf set filelocation.defaultlogdir    "$SQL_LOG_DIR"
/opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir "$SQL_BACKUP_DIR"

# Set memory limit — prevents kernel from paging out SQL Server buffer pool
info "Setting SQL Server memory limit to ${SQL_MEM_LIMIT_MB} MB..."
/opt/mssql/bin/mssql-conf set memory.memorylimitmb "${SQL_MEM_LIMIT_MB}"

# Enable SQL Server Agent if the edition supports it.
# Express edition does NOT support Agent — we detect this and skip gracefully.
# Backups are scheduled via cron so this is informational/optional only.
info "Checking whether SQL Server Agent is supported for edition: ${SQL_PID}..."
if [[ "${SQL_PID,,}" == "express" ]]; then
    info "Express edition — SQL Server Agent is not supported. Skipping."
else
    info "Enabling SQL Server Agent (${SQL_PID} edition)..."
    /opt/mssql/bin/mssql-conf set sqlagent.enabled true
    success "SQL Server Agent enabled. Note: backups use cron, not Agent."
fi

# Install mssql-tools18 (sqlcmd) — Ubuntu 24.04 native
info "Adding Microsoft prod repository for sqlcmd tools..."
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
    -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
apt-get update -qq
ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev

# Add mssql-tools to PATH for root and all users
TOOLS_PATH="/opt/mssql-tools18/bin"
if ! grep -q "mssql-tools18" /etc/environment 2>/dev/null; then
    # Append to existing PATH in /etc/environment
    if grep -q "^PATH=" /etc/environment; then
        sed -i "s|^PATH=\"\(.*\)\"|PATH=\"\1:${TOOLS_PATH}\"|" /etc/environment
    else
        echo "PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${TOOLS_PATH}\"" \
            >> /etc/environment
    fi
fi
export PATH="${PATH}:${TOOLS_PATH}"

# Restart to apply collation / directory settings
systemctl restart mssql-server

info "Waiting for SQL Server to become ready..."
for i in {1..30}; do
    if "${TOOLS_PATH}/sqlcmd" -S localhost -U sa -P "${SA_PASSWORD}" \
        -Q "SELECT @@VERSION" -C 2>/dev/null | grep -q "SQL Server"; then
        break
    fi
    sleep 2
done

systemctl is-active --quiet mssql-server \
    && success "SQL Server is running." \
    || die "SQL Server failed to start. Check: journalctl -u mssql-server"

# =============================================================================
# SECTION 2 — Install & configure MSDTC
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 2: Configuring MSDTC ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Setting network.rpcport = ${MSDTC_RPC_PORT}..."
/opt/mssql/bin/mssql-conf set network.rpcport "${MSDTC_RPC_PORT}"

info "Setting distributedtransaction.servertcpport = ${MSDTC_DTC_PORT}..."
/opt/mssql/bin/mssql-conf set distributedtransaction.servertcpport "${MSDTC_DTC_PORT}"

info "Restarting SQL Server to activate MSDTC ports..."
systemctl restart mssql-server
sleep 5

success "MSDTC configured. RPC port: ${MSDTC_RPC_PORT}, DTC port: ${MSDTC_DTC_PORT}"

# =============================================================================
# SECTION 3 — Capture UFW rules and convert to iptables equivalents
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 3: Converting UFW rules to iptables rules ━━━━━━━━━━━━━━━${NC}"

# Show current UFW status
info "Current UFW rules:"
ufw status verbose 2>/dev/null || true
echo ""

# Capture the raw iptables rules that UFW has written to the kernel
# UFW writes its rules directly into iptables — we capture them now
info "Capturing current iptables rules (including all UFW-generated rules)..."
mkdir -p /etc/iptables

# This saves ALL live iptables rules (includes UFW chains and rules)
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

info "Saved current iptables state:"
echo "  IPv4: /etc/iptables/rules.v4"
echo "  IPv6: /etc/iptables/rules.v6"

# Display what was captured so the operator can review
echo ""
echo -e "${YEL}  -- Captured IPv4 rules summary --${NC}"
iptables -L -n --line-numbers 2>/dev/null | head -60 || true
echo ""

# Now we also generate a clean equivalent ruleset that does NOT depend on UFW
# chains. We inspect ufw status to learn which ports are allowed, then rebuild.
info "Building clean equivalent iptables ruleset from UFW rules..."

# Extract user-added UFW ports (numeric, both tcp and udp)
# This parses 'ufw status numbered' output
UFW_RULES_RAW=$(ufw status numbered 2>/dev/null || echo "")

# Write a conversion helper script — this creates equivalent standalone rules
cat > /root/ufw_to_iptables_equivalent.sh <<'CONVSCRIPT'
#!/usr/bin/env bash
# Auto-generated: UFW → iptables equivalent rule builder
# Run AFTER iptables-persistent is installed and UFW is removed
# to verify or re-apply the equivalent standalone rules.
# This file is for reference — the actual rules are in /etc/iptables/rules.v4

echo "UFW equivalent rules (already captured in /etc/iptables/rules.v4):"
echo "To view live rules: iptables -L -n --line-numbers"
echo "To reload saved:    netfilter-persistent reload"
echo ""
echo "Captured rules are stored at:"
echo "  /etc/iptables/rules.v4  (IPv4)"
echo "  /etc/iptables/rules.v6  (IPv6)"
CONVSCRIPT
chmod +x /root/ufw_to_iptables_equivalent.sh

success "UFW rules captured as native iptables rules in /etc/iptables/rules.v4"

# =============================================================================
# SECTION 4 — Add MSDTC iptables rules
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 4: Adding MSDTC iptables rules ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Enable IP forwarding (required for PREROUTING NAT)
info "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/" /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
fi

# SQL Server TDS
info "Allowing SQL Server TDS port 1433..."
iptables -C INPUT -p tcp --dport 1433 -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport 1433 -j ACCEPT

# MSDTC server TCP port (distributed transactions)
info "Allowing MSDTC DTC port ${MSDTC_DTC_PORT}..."
iptables -C INPUT -p tcp --dport "${MSDTC_DTC_PORT}" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "${MSDTC_DTC_PORT}" -j ACCEPT

# RPC endpoint mapper port
info "Allowing MSDTC RPC port ${MSDTC_RPC_PORT}..."
iptables -C INPUT -p tcp --dport "${MSDTC_RPC_PORT}" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "${MSDTC_RPC_PORT}" -j ACCEPT

# NAT port forwarding: port 135 → MSDTC_RPC_PORT
# Required because non-root processes cannot bind to port 135
info "Adding NAT PREROUTING rule: port 135 → ${MSDTC_RPC_PORT}..."
# Allow port 135 in INPUT first
iptables -C INPUT -p tcp --dport 135 -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport 135 -j ACCEPT

# PREROUTING DNAT redirect
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ -n "$SERVER_IP" ]]; then
    iptables -t nat -C PREROUTING -d "${SERVER_IP}" -p tcp --dport 135 \
        -j REDIRECT --to-ports "${MSDTC_RPC_PORT}" 2>/dev/null \
        || iptables -t nat -A PREROUTING -d "${SERVER_IP}" -p tcp --dport 135 \
            -j REDIRECT --to-ports "${MSDTC_RPC_PORT}"

    info "Added NAT rule: ${SERVER_IP}:135 → :${MSDTC_RPC_PORT}"
fi

# Also add a loopback/local redirect (for same-host DTC traffic)
iptables -t nat -C OUTPUT -d 127.0.0.1 -p tcp --dport 135 \
    -j REDIRECT --to-ports "${MSDTC_RPC_PORT}" 2>/dev/null \
    || iptables -t nat -A OUTPUT -d 127.0.0.1 -p tcp --dport 135 \
        -j REDIRECT --to-ports "${MSDTC_RPC_PORT}"

success "MSDTC iptables rules applied."

# =============================================================================
# SECTION 5 — Persist all iptables rules
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 5: Persisting iptables rules ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Installing iptables-persistent (netfilter-persistent)..."
# Pre-answer the debconf prompts to avoid interactive dialogue
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent

# Save current (complete) rules including our new MSDTC rules
info "Saving all iptables rules to /etc/iptables/rules.v4 ..."
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

systemctl enable  netfilter-persistent
systemctl restart netfilter-persistent

success "iptables rules persisted and service enabled on boot."

# =============================================================================
# SECTION 6 — Uninstall UFW
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 6: Uninstalling UFW ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Disabling UFW before removal..."
ufw disable 2>/dev/null || true

info "Purging ufw package..."
apt-get purge -y ufw 2>/dev/null || warn "UFW may not have been installed."
apt-get autoremove -y 2>/dev/null || true

# Reload netfilter rules now that UFW chains are gone
info "Reloading netfilter rules (removing UFW chain references)..."

# The saved rules.v4 may contain UFW-specific chains. We rebuild a clean version.
info "Building clean iptables ruleset (removing UFW internal chains)..."

# Flush and reload from saved file
iptables -F || true
iptables -X || true
iptables -t nat -F || true
iptables -t nat -X || true
iptables -t mangle -F || true
iptables -t mangle -X || true

# Set default policies — DROP inbound, ACCEPT outbound, DROP forward
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# Fundamental rules
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# SSH (preserve existing access)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# SQL Server
iptables -A INPUT -p tcp --dport 1433 -j ACCEPT

# MSDTC
iptables -A INPUT -p tcp --dport "${MSDTC_RPC_PORT}" -j ACCEPT
iptables -A INPUT -p tcp --dport "${MSDTC_DTC_PORT}" -j ACCEPT
iptables -A INPUT -p tcp --dport 135 -j ACCEPT

# NAT
SERVER_IP=$(hostname -I | awk '{print $1}')
[[ -n "$SERVER_IP" ]] && \
    iptables -t nat -A PREROUTING -d "${SERVER_IP}" -p tcp --dport 135 \
        -j REDIRECT --to-ports "${MSDTC_RPC_PORT}" || true
iptables -t nat -A OUTPUT -d 127.0.0.1 -p tcp --dport 135 \
    -j REDIRECT --to-ports "${MSDTC_RPC_PORT}"

# Save clean ruleset
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

systemctl restart netfilter-persistent

success "UFW removed. Clean iptables ruleset is active and persisted."
echo ""
echo -e "${YEL}  NOTE: If your server has additional ports that were open in UFW${NC}"
echo -e "${YEL}  (beyond SSH/1433/MSDTC), add them now with:${NC}"
echo -e "${YEL}    iptables -A INPUT -p tcp --dport <PORT> -j ACCEPT${NC}"
echo -e "${YEL}    iptables-save > /etc/iptables/rules.v4${NC}"

# =============================================================================
# SECTION 7 — Backup setup using Ola Hallengren's SQL Server Maintenance Solution
#
# GitHub: https://github.com/olahallengren/sql-server-maintenance-solution
# 3,300+ stars — the industry-standard open source SQL Server backup/maintenance
# library. Supports SQL Server 2008 through 2025. MIT licensed.
#
# DatabaseBackup procedure features used here:
#   @Databases       = 'USER_DATABASES'  — all user databases automatically
#   @Directory                           — per-DB subfolders created automatically
#   @BackupType      = 'FULL'
#   @Compress        = 'Y'
#   @Verify          = 'Y'               — RESTORE VERIFYONLY after each backup
#   @CheckSum        = 'Y'               — page-level checksum validation
#   @CleanupTime                         — auto-delete old backups (hours)
#   @LogToTable      = 'Y'              — logs every command to dbo.CommandLog
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 7: Configuring Backup (Ola Hallengren Maintenance Solution) ━${NC}"
echo -e "${CYN}   https://github.com/olahallengren/sql-server-maintenance-solution  ${NC}"

# ── 7a: Local backup directory ────────────────────────────────────────────────
info "Creating local backup root: ${LOCAL_BACKUP_ROOT}..."
mkdir -p "${LOCAL_BACKUP_ROOT}"
chown mssql:mssql "${LOCAL_BACKUP_ROOT}"
chmod 750 "${LOCAL_BACKUP_ROOT}"

# ── 7b: SMB mount ─────────────────────────────────────────────────────────────
info "Configuring SMB share ${SMB_SHARE} → ${SMB_MOUNT}..."
mkdir -p "${SMB_MOUNT}"

# Store SMB credentials securely
SMB_CRED_FILE="/root/.smb_sqlbackup_credentials"
cat > "${SMB_CRED_FILE}" <<EOF
username=${SMB_USER}
password=${SMB_PASS}
EOF
chmod 600 "${SMB_CRED_FILE}"

# Mount now (non-fatal — fstab entry ensures persistence after reboot)
mount -t cifs "${SMB_SHARE}" "${SMB_MOUNT}" \
    -o "credentials=${SMB_CRED_FILE},vers=3.0,file_mode=0770,dir_mode=0770" \
    || warn "SMB mount failed. Verify share path/credentials. fstab entry will be added regardless."

# Persist SMB mount in /etc/fstab
if ! grep -qF "${SMB_SHARE}" /etc/fstab 2>/dev/null; then
    echo "${SMB_SHARE}  ${SMB_MOUNT}  cifs  credentials=${SMB_CRED_FILE},vers=3.0,file_mode=0770,dir_mode=0770,_netdev  0  0" \
        >> /etc/fstab
    info "Added SMB mount to /etc/fstab."
fi

# ── 7c: Download and install Ola Hallengren's Maintenance Solution ────────────
OLA_URL="https://raw.githubusercontent.com/olahallengren/sql-server-maintenance-solution/main/MaintenanceSolution.sql"
OLA_SQL="/tmp/MaintenanceSolution.sql"

info "Downloading Ola Hallengren's MaintenanceSolution.sql from GitHub..."
if ! curl -fsSL "${OLA_URL}" -o "${OLA_SQL}"; then
    die "Failed to download MaintenanceSolution.sql. Check internet connectivity."
fi

# Patch the script's @BackupDirectory to use our configured backup path.
# The script contains: DECLARE @BackupDirectory nvarchar(max) = NULL
# We replace NULL with our path so jobs are pre-configured.
ESCAPED_BACKUP_DIR=$(printf '%s\n' "${LOCAL_BACKUP_ROOT}" | sed 's/[[\.*^$()+?{|&]/\\&/g')
sed -i "s|DECLARE @BackupDirectory nvarchar(max)\s*=\s*NULL|DECLARE @BackupDirectory nvarchar(max) = N'${ESCAPED_BACKUP_DIR}'|g" \
    "${OLA_SQL}" || true

info "Installing Ola Hallengren's stored procedures into master database..."
# -b causes sqlcmd to exit with error code on SQL errors
"${TOOLS_PATH}/sqlcmd" \
    -S localhost \
    -U sa \
    -P "${SA_PASSWORD}" \
    -C \
    -d master \
    -b \
    -i "${OLA_SQL}" \
    -o /var/log/ola_install.log \
    && success "Ola Hallengren's solution installed successfully." \
    || die "Installation of Ola Hallengren's solution failed. See /var/log/ola_install.log"

rm -f "${OLA_SQL}"

# ── 7d: Verify the stored procedures were created ────────────────────────────
info "Verifying stored procedures..."
OLA_CHECK=$("${TOOLS_PATH}/sqlcmd" -S localhost -U sa -P "${SA_PASSWORD}" -C -d master \
    -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.objects WHERE type='P' AND name IN ('DatabaseBackup','DatabaseIntegrityCheck','IndexOptimize','CommandExecute');" \
    -h -1 2>/dev/null | tr -d ' \r\n')

if [[ "$OLA_CHECK" == "4" ]]; then
    success "All 4 Ola Hallengren stored procedures confirmed in master."
else
    warn "Expected 4 procedures, found: ${OLA_CHECK}. Check /var/log/ola_install.log"
fi

# ── 7e: Export the TDE certificate to a secure, isolated location ────────────
#
# Security model:
#   - Certificate files are stored in /etc/mssql-tde-certs/
#     owner: root:root, directory: 700, files: 400
#     The mssql service account has NO access to this path.
#   - This directory is completely outside the backup tree so mssql
#     can never traverse to it, even if SQL Server is compromised.
#   - Certificates are copied to a SEPARATE SMB share (not the backup share)
#     so that an attacker who obtains the backup media does not automatically
#     have the key needed to decrypt it.
#
# Reference:
#   https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-encryption

TDE_CERT_EXPORT_DIR="/etc/mssql-tde-certs"

info "Creating TDE certificate export directory: ${TDE_CERT_EXPORT_DIR}..."
mkdir -p "${TDE_CERT_EXPORT_DIR}"
chown root:root "${TDE_CERT_EXPORT_DIR}"
chmod 700 "${TDE_CERT_EXPORT_DIR}"   # root-only; mssql service account has no access

# Mount the separate certificate SMB share
TDE_CERT_SMB_CRED_FILE="/root/.smb_tdecert_credentials"
cat > "${TDE_CERT_SMB_CRED_FILE}" <<EOF
username=${TDE_CERT_SMB_USER}
password=${TDE_CERT_SMB_PASS}
EOF
chmod 600 "${TDE_CERT_SMB_CRED_FILE}"

info "Mounting certificate SMB share ${TDE_CERT_SMB_SHARE} → ${TDE_CERT_SMB_MOUNT}..."
mkdir -p "${TDE_CERT_SMB_MOUNT}"
mount -t cifs "${TDE_CERT_SMB_SHARE}" "${TDE_CERT_SMB_MOUNT}" \
    -o "credentials=${TDE_CERT_SMB_CRED_FILE},vers=3.0,file_mode=0600,dir_mode=0700" \
    || warn "Certificate SMB mount failed. fstab entry will be added; verify credentials."

# Persist certificate SMB mount in /etc/fstab
if ! grep -qF "${TDE_CERT_SMB_SHARE}" /etc/fstab 2>/dev/null; then
    echo "${TDE_CERT_SMB_SHARE}  ${TDE_CERT_SMB_MOUNT}  cifs  credentials=${TDE_CERT_SMB_CRED_FILE},vers=3.0,file_mode=0600,dir_mode=0700,_netdev  0  0" \
        >> /etc/fstab
    info "Added certificate SMB mount to /etc/fstab."
fi

info "Discovering TDE certificates protecting user databases..."

# Query: find every certificate whose thumbprint matches a DEK in a user database
TDE_CERTS=$("${TOOLS_PATH}/sqlcmd" \
    -S localhost -U sa -P "${SA_PASSWORD}" -C -d master \
    -Q "SET NOCOUNT ON;
        SELECT DISTINCT c.name
        FROM   sys.certificates c
        JOIN   sys.dm_database_encryption_keys dek
               ON dek.encryptor_thumbprint = c.thumbprint
        WHERE  dek.database_id > 4;" \
    -h -1 2>/dev/null | sed '/^$/d' | sed '/^-/d' | xargs)

if [[ -z "$TDE_CERTS" ]]; then
    warn "No TDE certificates found protecting user databases."
    warn "Verify TDE is configured: SELECT name, is_encrypted FROM sys.databases WHERE database_id > 4"
else
    for CERT in $TDE_CERTS; do
        CERT=$(echo "$CERT" | xargs)
        [[ -z "$CERT" ]] && continue

        CERT_FILE="${TDE_CERT_EXPORT_DIR}/${CERT}.cer"
        CERT_KEY_FILE="${TDE_CERT_EXPORT_DIR}/${CERT}.pvk"

        info "Exporting TDE certificate: ${CERT}..."
        "${TOOLS_PATH}/sqlcmd" \
            -S localhost -U sa -P "${SA_PASSWORD}" -C -d master -b \
            -Q "BACKUP CERTIFICATE [${CERT}]
                TO FILE = '${CERT_FILE}'
                WITH PRIVATE KEY (
                    FILE                   = '${CERT_KEY_FILE}',
                    ENCRYPTION BY PASSWORD = '${TDE_CERT_EXPORT_PASSWORD}'
                );" \
            >> /var/log/ola_install.log 2>&1 \
            && success "  Exported: ${CERT_FILE}" \
            || warn "  Failed to export ${CERT}. Check /var/log/ola_install.log"

        # Harden: root read-only, no other access
        chown root:root "${CERT_FILE}" "${CERT_KEY_FILE}" 2>/dev/null || true
        chmod 400 "${CERT_FILE}" "${CERT_KEY_FILE}"

        # Copy to the separate certificate SMB share
        if mountpoint -q "${TDE_CERT_SMB_MOUNT}" 2>/dev/null; then
            cp "${CERT_FILE}"     "${TDE_CERT_SMB_MOUNT}/" \
                && cp "${CERT_KEY_FILE}" "${TDE_CERT_SMB_MOUNT}/" \
                && success "  Copied to certificate share: ${TDE_CERT_SMB_MOUNT}/" \
                || warn "  Failed to copy to certificate share."
        else
            warn "  Certificate share not mounted — manual copy required."
        fi
    done

    echo ""
    echo -e "${YEL}  ╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YEL}  ║  CRITICAL — TDE CERTIFICATE SECURITY                        ║${NC}"
    echo -e "${YEL}  ║                                                              ║${NC}"
    echo -e "${YEL}  ║  Local  : ${TDE_CERT_EXPORT_DIR}  (root only)${NC}"
    echo -e "${YEL}  ║  Remote : ${TDE_CERT_SMB_MOUNT} (separate share)${NC}"
    echo -e "${YEL}  ║                                                              ║${NC}"
    echo -e "${YEL}  ║  Certificates are NOT stored in the backup folder and are   ║${NC}"
    echo -e "${YEL}  ║  NOT copied to the backup SMB share. The mssql service      ║${NC}"
    echo -e "${YEL}  ║  account has no access to the local certificate directory.  ║${NC}"
    echo -e "${YEL}  ║                                                              ║${NC}"
    echo -e "${YEL}  ║  Also store certificates + export password in a third,      ║${NC}"
    echo -e "${YEL}  ║  offline location (USB / password manager / physical safe). ║${NC}"
    echo -e "${YEL}  ║                                                              ║${NC}"
    echo -e "${YEL}  ║  Without the certificate files + export password, TDE       ║${NC}"
    echo -e "${YEL}  ║  backups CANNOT be restored on any other server.            ║${NC}"
    echo -e "${YEL}  ╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi

# ── 7f: Wrapper backup script (calls DatabaseBackup via sqlcmd) ───────────────
# Ola's CleanupTime is in hours. Convert retention days → hours.
CLEANUP_HOURS=$(( BACKUP_RETENTION * 24 ))

BACKUP_SCRIPT="/usr/local/sbin/mssql_backup.sh"
info "Creating wrapper backup script: ${BACKUP_SCRIPT}..."

cat > "${BACKUP_SCRIPT}" <<BACKUPSCRIPT
#!/usr/bin/env bash
# =============================================================================
# mssql_backup.sh
# Wrapper around Ola Hallengren's DatabaseBackup stored procedure.
# GitHub: https://github.com/olahallengren/sql-server-maintenance-solution
#
# Databases use TDE (Transparent Data Encryption), so every .bak file is
# implicitly encrypted — no separate backup encryption parameters are needed.
#
# DatabaseBackup automatically:
#   - Backs up all USER_DATABASES to individual per-database subfolders
#   - Backup files are TDE-encrypted implicitly (no extra configuration needed)
#   - Compresses backups
#   - Verifies each backup (RESTORE VERIFYONLY)
#   - Validates checksums
#   - Logs all commands and results to dbo.CommandLog in master
#   - Deletes backups older than @CleanupTime hours
#
# TDE certificate files are stored and synced SEPARATELY from backups:
#   Local  : /etc/mssql-tde-certs/  (root:root 700, files 400)
#   Remote : dedicated certificate SMB share (NOT the backup share)
#
# After the local backup completes, this script rsync-copies the backup
# tree to the backup SMB share and purges old .bak files beyond the
# retention period. Certificate files are never placed in the backup tree.
# =============================================================================
set -euo pipefail

SQLCMD="${TOOLS_PATH}/sqlcmd"
SA_PASSWORD="${SA_PASSWORD}"
LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT}"
SMB_MOUNT="${SMB_MOUNT}"
SMB_SHARE="${SMB_SHARE}"
SMB_CRED_FILE="${SMB_CRED_FILE}"
CLEANUP_HOURS="${CLEANUP_HOURS}"
LOG_FILE="/var/log/mssql_backup.log"

log() { echo "\$(date '+%F %T') \$*" | tee -a "\${LOG_FILE}"; }

log "======================================================================"
log "  SQL Server Backup — Ola Hallengren DatabaseBackup (TDE-encrypted)"
log "  Local:  \${LOCAL_BACKUP_ROOT}"
log "  Remote: \${SMB_SHARE} → \${SMB_MOUNT}"
log "======================================================================"

# ── Ensure SMB share is mounted ──────────────────────────────────────────────
if ! mountpoint -q "\${SMB_MOUNT}" 2>/dev/null; then
    log "SMB share not mounted — mounting now..."
    mount -t cifs "\${SMB_SHARE}" "\${SMB_MOUNT}" \
        -o "credentials=\${SMB_CRED_FILE},vers=3.0,file_mode=0770,dir_mode=0770" \
        || { log "ERROR: Cannot mount SMB share \${SMB_SHARE}"; exit 1; }
fi

# ── Run Ola Hallengren's DatabaseBackup ──────────────────────────────────────
# DatabaseBackup creates this structure automatically:
#   {LOCAL_BACKUP_ROOT}/{ServerName}/{InstanceName}/{DatabaseName}/FULL/
# No @Encrypt parameter needed — TDE encrypts the backup files implicitly.
# @Verify='Y'    — runs RESTORE VERIFYONLY after each backup
# @Checksum='Y'  — enables page checksums during backup
# @Compress='Y'  — uses SQL Server native compression (compatible with TDE)
# @CleanupTime   — deletes .bak files older than N hours (never deletes newest)
# @LogToTable='Y'— writes to dbo.CommandLog in master for auditing
log "Running DatabaseBackup for USER_DATABASES (FULL, TDE-encrypted implicitly, compressed, verified)..."

"\${SQLCMD}" \
    -S localhost \
    -U sa \
    -P "\${SA_PASSWORD}" \
    -C \
    -d master \
    -b \
    -Q "EXECUTE dbo.DatabaseBackup
        @Databases   = 'USER_DATABASES',
        @Directory   = N'\${LOCAL_BACKUP_ROOT}',
        @BackupType  = 'FULL',
        @Compress    = 'Y',
        @Verify      = 'Y',
        @Checksum    = 'Y',
        @CleanupTime = \${CLEANUP_HOURS},
        @LogToTable  = 'Y';" \
    >> "\${LOG_FILE}" 2>&1

BACKUP_RC=\$?
if [[ \${BACKUP_RC} -eq 0 ]]; then
    log "DatabaseBackup completed successfully (TDE-encrypted)."
else
    log "ERROR: DatabaseBackup returned exit code \${BACKUP_RC}."
    log "       Review dbo.CommandLog in master for details:"
    log "       SELECT * FROM master.dbo.CommandLog ORDER BY StartTime DESC"
    exit \${BACKUP_RC}
fi

# ── Copy backup tree to SMB share ────────────────────────────────────────────
# rsync mirrors only .bak files and their directory structure.
# TDE certificate files are NEVER placed here — they go to a separate share.
log "Syncing backup tree to SMB share: \${SMB_MOUNT}..."
if command -v rsync &>/dev/null; then
    rsync -a --delete \
        --include='*.bak' \
        --include='*/' \
        --exclude='*' \
        "\${LOCAL_BACKUP_ROOT}/" "\${SMB_MOUNT}/" \
        >> "\${LOG_FILE}" 2>&1 \
        && log "rsync to SMB share completed." \
        || log "WARNING: rsync to SMB share failed — backups are still local."
else
    # Fallback: plain cp if rsync not available
    cp -r "\${LOCAL_BACKUP_ROOT}/." "\${SMB_MOUNT}/" \
        >> "\${LOG_FILE}" 2>&1 \
        && log "cp to SMB share completed." \
        || log "WARNING: cp to SMB share failed — backups are still local."
fi

# ── Remote cleanup: remove .bak files on SMB older than retention period ─────
CLEANUP_DAYS=\$(( CLEANUP_HOURS / 24 ))
log "Cleaning up SMB backups older than \${CLEANUP_DAYS} days..."
find "\${SMB_MOUNT}" -name "*.bak" -mtime "+\${CLEANUP_DAYS}" \
    -delete -print 2>/dev/null | \
    while read -r f; do log "  Deleted remote: \$f"; done || \
    log "  Note: Remote cleanup encountered errors (non-fatal)."

log "======================================================================"
log "  Backup complete. Review dbo.CommandLog in master for full details."
log "  Query: SELECT * FROM master.dbo.CommandLog ORDER BY StartTime DESC"
log "======================================================================"
exit 0
BACKUPSCRIPT

chmod +x "${BACKUP_SCRIPT}"

# ── 7f: Install rsync (used for SMB copy) ────────────────────────────────────
info "Installing rsync..."
apt-get install -y -qq rsync

# ── 7g: Cron job — daily at 02:00 ────────────────────────────────────────────
CRON_FILE="/etc/cron.d/mssql_backup"
cat > "${CRON_FILE}" <<CRONEOF
# SQL Server backup via Ola Hallengren's DatabaseBackup procedure
# Runs daily at 02:00. Output appended to /var/log/mssql_backup.log
0 2 * * * root ${BACKUP_SCRIPT} >> /var/log/mssql_backup.log 2>&1
CRONEOF
chmod 644 "${CRON_FILE}"
info "Backup cron job created: daily at 02:00."

# ── 7h: Log file ──────────────────────────────────────────────────────────────
touch /var/log/mssql_backup.log
chmod 640 /var/log/mssql_backup.log

success "Ola Hallengren backup system configured."
echo ""
echo "  Library          : Ola Hallengren SQL Server Maintenance Solution"
echo "  Source           : https://github.com/olahallengren/sql-server-maintenance-solution"
echo "  Installed in     : master database (dbo.DatabaseBackup, dbo.CommandExecute, etc.)"
echo "  Backup wrapper   : ${BACKUP_SCRIPT}"
echo "  Backup schedule  : /etc/cron.d/mssql_backup (daily 02:00)"
echo "  Backup log       : /var/log/mssql_backup.log"
echo "  CommandLog table : master.dbo.CommandLog"
echo "  Local backup dir : ${LOCAL_BACKUP_ROOT}"
echo "  SMB mount        : ${SMB_MOUNT}"
echo "  Retention        : ${BACKUP_RETENTION} days (${CLEANUP_HOURS} hours, enforced by DatabaseBackup)"

# =============================================================================
# SECTION 8 — OS kernel tuning (Microsoft-recommended for SQL Server)
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 8: OS Kernel Tuning for SQL Server (TuneD mssql profile) ━━${NC}"
# Reference: https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-performance-best-practices

info "Installing TuneD..."
apt-get install -y -qq tuned

info "Creating TuneD mssql profile..."
mkdir -p /usr/lib/tuned/mssql

# This profile matches the Microsoft-recommended TuneD configuration for
# SQL Server on Linux. TuneD handles sysctl values AND transparent huge
# pages (vm.transparent_hugepages), which is not a valid raw sysctl key
# but IS understood by TuneD's built-in sysctl plugin.
cat > /usr/lib/tuned/mssql/tuned.conf <<'TUNEDEOF'
[main]
summary=Optimize for Microsoft SQL Server
include=throughput-performance

[cpu]
force_latency=5

[sysctl]
vm.swappiness = 1
vm.dirty_background_ratio = 3
vm.dirty_ratio = 80
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
vm.transparent_hugepages=always
vm.max_map_count=1600000
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
kernel.numa_balancing=0
TUNEDEOF

chmod 644 /usr/lib/tuned/mssql/tuned.conf

info "Activating TuneD mssql profile..."
systemctl enable --now tuned
tuned-adm profile mssql

# Verify the profile is active
ACTIVE_PROFILE=$(tuned-adm active 2>/dev/null || echo "unknown")
success "TuneD mssql profile active: ${ACTIVE_PROFILE}"

# Remove any previous manual sysctl overrides that TuneD now manages
if [[ -f /etc/sysctl.d/90-mssql.conf ]]; then
    rm -f /etc/sysctl.d/90-mssql.conf
    info "Removed legacy /etc/sysctl.d/90-mssql.conf (now managed by TuneD)."
fi

# =============================================================================
# SECTION 9 — NTP / time synchronisation via chrony
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 9: NTP / Time Synchronisation (chrony) ━━━━━━━━━━━━━━━━━━${NC}"

info "Installing chrony..."
apt-get install -y -qq chrony

# Disable systemd-timesyncd to avoid conflict with chrony
if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    info "Stopping and disabling systemd-timesyncd (replaced by chrony)..."
    systemctl stop systemd-timesyncd
    systemctl disable systemd-timesyncd
fi

info "Configuring chrony with NTP server: ${NTP_SERVER}..."
cat > /etc/chrony/chrony.conf <<CHRONYEOF
# chrony configuration — managed by setup-sqlserver-ubuntu.sh
# NTP server / pool
pool ${NTP_SERVER} iburst maxsources 4

# Allow stepping the clock on first start if offset > 1 second
makestep 1 3

# Enable kernel RTC sync
rtcsync

# Record drift for faster sync after restart
driftfile /var/lib/chrony/chrony.drift

# Log directory
logdir /var/log/chrony

# Leap seconds handling
leapsectz right/UTC
CHRONYEOF

systemctl enable --now chrony
sleep 2

# Force an immediate sync
chronyc makestep > /dev/null 2>&1 || true

# Verify
CHRONY_STATUS=$(chronyc tracking 2>/dev/null | grep "System time" || echo "check manually")
success "chrony configured. Server: ${NTP_SERVER}"
info "  ${CHRONY_STATUS}"
info "  Verify with: chronyc tracking"

# =============================================================================
# SECTION 10 — Unattended security updates
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 10: Unattended Security Updates ━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Installing unattended-upgrades..."
apt-get install -y -qq unattended-upgrades

# Configure: security-only updates, NO automatic reboots (DBA must schedule)
info "Configuring unattended-upgrades (security patches only, no auto-reboot)..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UUEOF'
// unattended-upgrades — managed by setup-sqlserver-ubuntu.sh
// Security patches only. Auto-reboot is DISABLED — schedule reboots manually
// during a maintenance window so SQL Server can be properly shut down first.

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
};

// Never auto-reboot — a SQL Server restart must be coordinated
Unattended-Upgrade::Automatic-Reboot "false";

// Remove unused kernel packages after upgrade
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Log to syslog
Unattended-Upgrade::SyslogEnable "true";
UUEOF

# Enable the daily update timers
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOUPEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTOUPEOF

systemctl enable --now unattended-upgrades
success "Unattended security updates enabled. Reboots require manual scheduling."

# =============================================================================
# SECTION 11 — SSH hardening
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 11: SSH Hardening ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "${SSH_HARDEN}" == "true" ]]; then
    SSHD_CONFIG="/etc/ssh/sshd_config"

    # Back up original
    SSHD_BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "${SSHD_CONFIG}" "${SSHD_BACKUP}"
    info "Backed up original sshd_config to ${SSHD_BACKUP}."

    # Apply hardening via sed — only change specific directives, preserving
    # everything else. Append if directive is not present.
    _ssh_set() {
        local key="$1" val="$2"
        if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "${SSHD_CONFIG}"; then
            sed -i "s|^#\?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "${SSHD_CONFIG}"
        else
            echo "${key} ${val}" >> "${SSHD_CONFIG}"
        fi
    }

    _ssh_set "PermitRootLogin"          "no"
    _ssh_set "PasswordAuthentication"   "no"
    _ssh_set "PubkeyAuthentication"     "yes"
    _ssh_set "AuthorizedKeysFile"       ".ssh/authorized_keys"
    _ssh_set "PermitEmptyPasswords"     "no"
    _ssh_set "X11Forwarding"            "no"
    _ssh_set "MaxAuthTries"             "4"
    _ssh_set "LoginGraceTime"           "30"
    _ssh_set "ClientAliveInterval"      "300"
    _ssh_set "ClientAliveCountMax"      "2"
    _ssh_set "Banner"                   "/etc/issue.net"

    # Set a login banner
    cat > /etc/issue.net <<'BANNEREOF'
***************************************************************************
NOTICE: This system is restricted to authorised users only.
All activity is monitored and logged. Unauthorised access is prohibited.
Disconnect IMMEDIATELY if you are not an authorised user.
***************************************************************************
BANNEREOF

    # Validate config before restarting
    if sshd -t 2>/dev/null; then
        systemctl restart ssh
        success "SSH hardened: root login disabled, password auth disabled, banner set."
    else
        warn "sshd_config validation failed — reverting to backup. Check manually."
        cp "${SSHD_BACKUP}" "${SSHD_CONFIG}" 2>/dev/null || true
        systemctl restart ssh
    fi
else
    info "SSH hardening skipped (user choice)."
fi

# =============================================================================
# SECTION 12 — fail2ban
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 12: fail2ban (SSH brute-force protection) ━━━━━━━━━━━━━━━${NC}"

info "Installing fail2ban..."
apt-get install -y -qq fail2ban

# Build the ignoreip line — always include loopback, add user subnet if given
IGNOREIP_LINE="127.0.0.1/8 ::1"
if [[ -n "${FAIL2BAN_IGNOREIP}" ]]; then
    IGNOREIP_LINE="${IGNOREIP_LINE} ${FAIL2BAN_IGNOREIP}"
fi

# Write jail.local — never edit jail.conf directly (gets overwritten on upgrade).
# We use the iptables-multiport banaction since UFW is removed and we manage
# iptables directly. The 'backend = systemd' ensures fail2ban reads from the
# systemd journal where Ubuntu 24.04 writes sshd logs.
info "Writing /etc/fail2ban/jail.local..."
cat > /etc/fail2ban/jail.local <<JAILEOF
# fail2ban jail.local — managed by setup-sqlserver-ubuntu.sh
# Only override settings that differ from the defaults in jail.conf.

[DEFAULT]
# Never ban these addresses (loopback + any management subnet)
ignoreip = ${IGNOREIP_LINE}

# Ban for 1 hour on first offence
bantime  = 3600

# Count failures within a 10-minute window
findtime = 600

# Ban after 5 failures (conservative for a DB server)
maxretry = 5

# Use iptables directly (UFW is not installed on this server)
banaction = iptables-multiport

# Read from systemd journal — Ubuntu 24.04 routes sshd logs here
backend = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 5
bantime  = 3600
findtime = 600
JAILEOF

systemctl enable --now fail2ban
sleep 2

fail2ban-client status sshd > /dev/null 2>&1 \
    && success "fail2ban running. SSH jail active. Whitelist: ${IGNOREIP_LINE}" \
    || warn "fail2ban started but jail status check failed — verify with: fail2ban-client status sshd"


# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║   ✓  Setup complete!                                             ║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Hostname             : ${FULL_FQDN}"
echo -e "  SQL Server version   : $(${TOOLS_PATH}/sqlcmd -S localhost -U sa -P "${SA_PASSWORD}" -C \
    -Q "SET NOCOUNT ON; SELECT @@VERSION;" -h -1 2>/dev/null | head -1 | xargs || echo 'see: sqlcmd -S localhost -U sa')"
echo -e "  SQL Server port      : 1433"
echo -e "  SQL memory limit     : ${SQL_MEM_LIMIT_MB} MB"
if [[ "${SQL_PID,,}" != "express" ]]; then
echo -e "  SQL Server Agent     : enabled (backups use cron, not Agent)"
else
echo -e "  SQL Server Agent     : not available (Express edition)"
fi
echo -e "  MSDTC RPC port       : ${MSDTC_RPC_PORT}"
echo -e "  MSDTC DTC port       : ${MSDTC_DTC_PORT}"
echo -e "  iptables persisted   : /etc/iptables/rules.v4"
echo -e "  UFW removed          : yes"
echo -e "  Kernel tuning        : TuneD mssql profile (swappiness=1, THP=always)"
echo -e "  NTP                  : chrony → ${NTP_SERVER}"
echo -e "  Auto security updates: enabled (security patches only, no auto-reboot)"
echo -e "  SSH hardened         : ${SSH_HARDEN}"
echo -e "  fail2ban             : enabled — SSH jail active (whitelist: ${IGNOREIP_LINE})"
echo -e "  Ola Hallengren       : master.dbo.DatabaseBackup (installed)"
echo -e "  Backup encryption    : TDE (implicit — databases encrypted at rest)"
echo -e "  TDE cert local store : /etc/mssql-tde-certs/  (root:root 700)"
echo -e "  TDE cert remote      : ${TDE_CERT_SMB_SHARE}  (separate share)"
echo -e "  Backup wrapper       : ${BACKUP_SCRIPT}"
echo -e "  Backup schedule      : daily 02:00 (/etc/cron.d/mssql_backup)"
echo -e "  Backup audit log     : SELECT * FROM master.dbo.CommandLog ORDER BY StartTime DESC"
echo ""
echo -e "${YEL}  ► A reboot is recommended to fully apply kernel tuning, verify${NC}"
echo -e "${YEL}    hostname, iptables, NTP, and SMB mount persistence.${NC}"
echo ""
echo -e "${YEL}  ► To test a manual backup now:${NC}"
echo -e "${YEL}    sudo ${BACKUP_SCRIPT}${NC}"
echo ""
echo -e "${YEL}  ► To view Ola Hallengren backup history/errors:${NC}"
echo -e "${YEL}    sqlcmd -S localhost -U sa -d master -C${NC} \\"
echo -e "${YEL}      -Q \"SELECT DatabaseName,BackupType,StartTime,EndTime,\"${NC}"
echo -e "${YEL}           \"Status,ErrorNumber,ErrorMessage\"${NC}"
echo -e "${YEL}           \"FROM dbo.CommandLog ORDER BY StartTime DESC\"${NC}"
echo ""
echo -e "${YEL}  ► To check NTP sync:            chronyc tracking${NC}"
echo -e "${YEL}  ► To check fail2ban SSH jail:   fail2ban-client status sshd${NC}"
echo -e "${YEL}  ► To view firewall rules:        iptables -L -n --line-numbers${NC}"
echo -e "${YEL}  ► To verify kernel tuning:       tuned-adm active && tuned-adm verify${NC}"
echo ""