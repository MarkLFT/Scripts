#!/usr/bin/env bash
# =============================================================================
# migrate-ufw-to-iptables.sh
# Ubuntu — Migrate running SQL Server host from UFW to iptables-legacy
#
# Tasks:
#  1. Detect current MSDTC port configuration from mssql-conf
#  2. Snapshot current UFW rules and live iptables state for reference
#  3. Switch from iptables-nft to iptables-legacy (required for MSDTC)
#  4. Flush nftables ruleset and disable nftables
#  5. Disable and purge UFW
#  6. Install iptables-persistent
#  7. Build a clean iptables ruleset (preserving all ports UFW had open)
#  8. Add MSDTC rules (INPUT + NAT PREROUTING/OUTPUT for port 135 redirect)
#  9. Persist and enable on boot
#
# Why iptables-legacy: Microsoft's MSDTC on Linux requires classic iptables.
# The nf_tables backend (iptables-nft / nft) that ships as default on Ubuntu
# 22.04+ is not supported by MSDTC. This script switches the system to
# iptables-legacy so all tables (filter, nat, mangle) work correctly.
#
# Requirements: Run as root or via sudo on a server already running SQL Server.
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

# =============================================================================
# STEP 1 — Detect MSDTC port configuration
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 1: Detecting MSDTC port configuration ━━━━━━━━━━━━━━━━━━${NC}"

MSDTC_RPC_PORT=13500
MSDTC_DTC_PORT=51999

# Read from mssql-conf if available
MSSQL_CONF="/var/opt/mssql/mssql.conf"
if [[ -f "$MSSQL_CONF" ]]; then
    info "Reading MSDTC ports from ${MSSQL_CONF}..."

    # Extract network.rpcport
    RPC_FROM_CONF=$(grep -oP '^\s*rpcport\s*=\s*\K[0-9]+' "$MSSQL_CONF" 2>/dev/null || true)
    if [[ -n "$RPC_FROM_CONF" ]]; then
        MSDTC_RPC_PORT="$RPC_FROM_CONF"
    fi

    # Extract distributedtransaction.servertcpport
    DTC_FROM_CONF=$(grep -oP '^\s*servertcpport\s*=\s*\K[0-9]+' "$MSSQL_CONF" 2>/dev/null || true)
    if [[ -n "$DTC_FROM_CONF" ]]; then
        MSDTC_DTC_PORT="$DTC_FROM_CONF"
    fi
else
    warn "mssql.conf not found at ${MSSQL_CONF} — using default ports."
fi

info "MSDTC RPC port (network.rpcport):                ${MSDTC_RPC_PORT}"
info "MSDTC DTC port (distributedtransaction.servertcpport): ${MSDTC_DTC_PORT}"

# =============================================================================
# STEP 2 — Snapshot current UFW rules and iptables state
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 2: Capturing current firewall state ━━━━━━━━━━━━━━━━━━━━━${NC}"

SNAPSHOT_DIR="/root/firewall-migration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SNAPSHOT_DIR"

# Capture UFW status
info "Capturing UFW status..."
ufw status verbose > "$SNAPSHOT_DIR/ufw-status.txt" 2>&1 || \
    echo "UFW not active or not installed" > "$SNAPSHOT_DIR/ufw-status.txt"

ufw status numbered > "$SNAPSHOT_DIR/ufw-status-numbered.txt" 2>&1 || true

# Capture live iptables rules (these include UFW-generated chains)
info "Capturing live iptables rules..."
iptables-save  > "$SNAPSHOT_DIR/iptables-v4-before.rules" 2>/dev/null || true
ip6tables-save > "$SNAPSHOT_DIR/iptables-v6-before.rules" 2>/dev/null || true
iptables -L -n --line-numbers > "$SNAPSHOT_DIR/iptables-v4-list.txt" 2>&1 || true
iptables -t nat -L -n --line-numbers > "$SNAPSHOT_DIR/iptables-nat-list.txt" 2>&1 || true

# Parse open ports from UFW for reference
info "Extracting open ports from UFW rules..."
UFW_PORTS=()
while IFS= read -r line; do
    # Match lines like "22/tcp  ALLOW IN  Anywhere"
    port=$(echo "$line" | grep -oP '^\s*\K[0-9]+(?=/tcp\s+ALLOW)' || true)
    if [[ -n "$port" ]]; then
        # Deduplicate
        if [[ ! " ${UFW_PORTS[*]:-} " =~ " ${port} " ]]; then
            UFW_PORTS+=("$port")
        fi
    fi
done < "$SNAPSHOT_DIR/ufw-status-numbered.txt"

# Also capture any UDP allow rules
UFW_UDP_PORTS=()
while IFS= read -r line; do
    port=$(echo "$line" | grep -oP '^\s*\K[0-9]+(?=/udp\s+ALLOW)' || true)
    if [[ -n "$port" ]]; then
        if [[ ! " ${UFW_UDP_PORTS[*]:-} " =~ " ${port} " ]]; then
            UFW_UDP_PORTS+=("$port")
        fi
    fi
done < "$SNAPSHOT_DIR/ufw-status-numbered.txt"

info "Snapshot saved to: ${SNAPSHOT_DIR}/"
echo "  UFW status         : ${SNAPSHOT_DIR}/ufw-status.txt"
echo "  UFW numbered rules : ${SNAPSHOT_DIR}/ufw-status-numbered.txt"
echo "  iptables v4 backup : ${SNAPSHOT_DIR}/iptables-v4-before.rules"
echo "  iptables v6 backup : ${SNAPSHOT_DIR}/iptables-v6-before.rules"
echo ""

if [[ ${#UFW_PORTS[@]} -gt 0 ]]; then
    info "Detected UFW TCP ALLOW ports: ${UFW_PORTS[*]}"
else
    warn "No TCP ALLOW rules detected from UFW — will use standard SQL Server ports."
fi

if [[ ${#UFW_UDP_PORTS[@]} -gt 0 ]]; then
    info "Detected UFW UDP ALLOW ports: ${UFW_UDP_PORTS[*]}"
fi

# =============================================================================
# STEP 3 — Switch to iptables-legacy
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 3: Switching to iptables-legacy ━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Current iptables backend:"
iptables --version 2>/dev/null || true

# Flush the entire nftables ruleset first so the legacy module can load cleanly
if command -v nft &>/dev/null; then
    info "Flushing nftables ruleset..."
    nft flush ruleset 2>/dev/null || true
fi

# Switch update-alternatives to iptables-legacy
info "Setting iptables alternative to iptables-legacy..."
update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || \
    warn "iptables-legacy alternative not available — may already be legacy."
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || \
    warn "ip6tables-legacy alternative not available — may already be legacy."

# Disable and stop nftables service if it exists
if systemctl list-unit-files nftables.service &>/dev/null; then
    info "Disabling nftables service..."
    systemctl stop nftables.service 2>/dev/null || true
    systemctl disable nftables.service 2>/dev/null || true
    systemctl mask nftables.service 2>/dev/null || true
fi

info "Verified iptables backend:"
iptables --version

success "Switched to iptables-legacy."

# =============================================================================
# STEP 4 — Disable and purge UFW
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 4: Disabling and removing UFW ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Disabling UFW..."
ufw disable 2>/dev/null || true

info "Purging ufw package..."
apt-get purge -y ufw 2>/dev/null || warn "UFW was not installed."
apt-get autoremove -y 2>/dev/null || true

success "UFW disabled and purged."

# =============================================================================
# STEP 5 — Install iptables-persistent
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 5: Installing iptables-persistent ━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Installing iptables-persistent (netfilter-persistent)..."
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent

success "iptables-persistent installed."

# =============================================================================
# STEP 6 — Build clean iptables ruleset
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 6: Building clean iptables ruleset ━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Flush everything
info "Flushing all iptables rules and chains..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Set default policies — DROP inbound, ACCEPT outbound, DROP forward
info "Setting default policies: INPUT=DROP, FORWARD=DROP, OUTPUT=ACCEPT..."
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# ── Fundamental rules ────────────────────────────────────────────────────────
info "Adding base rules (loopback, established, ICMP)..."
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# ── SSH ──────────────────────────────────────────────────────────────────────
info "Allowing SSH (port 22)..."
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# ── SMB / Samba ─────────────────────────────────────────────────────────────
info "Allowing SMB (TCP 445, TCP 139, UDP 137-138)..."
iptables -A INPUT -p tcp --dport 445 -j ACCEPT
iptables -A INPUT -p tcp --dport 139 -j ACCEPT
iptables -A INPUT -p udp --dport 137 -j ACCEPT
iptables -A INPUT -p udp --dport 138 -j ACCEPT

# ── SQL Server TDS ───────────────────────────────────────────────────────────
info "Allowing SQL Server TDS (port 1433)..."
iptables -A INPUT -p tcp --dport 1433 -j ACCEPT

# ── MSDTC ports ─────────────────────────────────────────────────────────────
info "Allowing MSDTC RPC port ${MSDTC_RPC_PORT}..."
iptables -A INPUT -p tcp --dport "${MSDTC_RPC_PORT}" -j ACCEPT

info "Allowing MSDTC DTC port ${MSDTC_DTC_PORT}..."
iptables -A INPUT -p tcp --dport "${MSDTC_DTC_PORT}" -j ACCEPT

info "Allowing port 135 (RPC Endpoint Mapper, will be redirected)..."
iptables -A INPUT -p tcp --dport 135 -j ACCEPT

# ── Additional ports from UFW ────────────────────────────────────────────────
# Add any TCP ports that were in UFW but not already covered above
STANDARD_TCP_PORTS="22 135 139 445 1433 ${MSDTC_RPC_PORT} ${MSDTC_DTC_PORT}"
for port in "${UFW_PORTS[@]:-}"; do
    [[ -z "$port" ]] && continue
    if [[ ! " $STANDARD_TCP_PORTS " =~ " $port " ]]; then
        info "Preserving additional UFW TCP port: ${port}..."
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    fi
done

# Add any UDP ports from UFW
for port in "${UFW_UDP_PORTS[@]:-}"; do
    [[ -z "$port" ]] && continue
    info "Preserving additional UFW UDP port: ${port}..."
    iptables -A INPUT -p udp --dport "$port" -j ACCEPT
done

success "Filter rules applied."

# =============================================================================
# STEP 7 — MSDTC NAT / port forwarding rules
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 7: Adding MSDTC NAT forwarding rules ━━━━━━━━━━━━━━━━━━━${NC}"

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

# NAT PREROUTING: external port 135 → MSDTC_RPC_PORT
# Required because non-root processes (like mssql) cannot bind to port 135
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ -n "$SERVER_IP" ]]; then
    info "Adding NAT PREROUTING: ${SERVER_IP}:135 -> :${MSDTC_RPC_PORT}..."
    iptables -t nat -A PREROUTING -d "${SERVER_IP}" -p tcp --dport 135 \
        -j REDIRECT --to-ports "${MSDTC_RPC_PORT}"
else
    warn "Could not detect server IP — skipping PREROUTING NAT rule."
    warn "Add manually: iptables -t nat -A PREROUTING -d <IP> -p tcp --dport 135 -j REDIRECT --to-ports ${MSDTC_RPC_PORT}"
fi

# NAT OUTPUT: loopback port 135 → MSDTC_RPC_PORT (for same-host DTC traffic)
info "Adding NAT OUTPUT: 127.0.0.1:135 -> :${MSDTC_RPC_PORT}..."
iptables -t nat -A OUTPUT -d 127.0.0.1 -p tcp --dport 135 \
    -j REDIRECT --to-ports "${MSDTC_RPC_PORT}"

success "MSDTC NAT forwarding rules applied."

# =============================================================================
# STEP 8 — Persist and verify
# =============================================================================
echo ""
echo -e "${CYN}━━ Step 8: Persisting iptables rules ━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

mkdir -p /etc/iptables

info "Saving rules to /etc/iptables/rules.v4 ..."
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

systemctl enable  netfilter-persistent
systemctl restart netfilter-persistent

success "iptables rules persisted and netfilter-persistent enabled on boot."

# ─── Final verification ──────────────────────────────────────────────────────
echo ""
echo -e "${CYN}━━ Verification ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
info "Active filter rules:"
iptables -L INPUT -n --line-numbers
echo ""
info "Active NAT rules:"
iptables -t nat -L -n --line-numbers
echo ""

# Save final state to snapshot dir for comparison
iptables-save > "$SNAPSHOT_DIR/iptables-v4-after.rules"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GRN}  Migration complete — UFW removed, iptables-legacy active${NC}"
echo -e "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  MSDTC RPC port       : ${MSDTC_RPC_PORT}"
echo -e "  MSDTC DTC port       : ${MSDTC_DTC_PORT}"
echo -e "  NAT 135 -> RPC port  : ${MSDTC_RPC_PORT}"
echo -e "  Server IP            : ${SERVER_IP:-unknown}"
echo -e "  Rules persisted      : /etc/iptables/rules.v4"
echo -e "  Pre-migration backup : ${SNAPSHOT_DIR}/"
echo ""
echo -e "${YEL}  To add more ports later:${NC}"
echo -e "${YEL}    iptables -A INPUT -p tcp --dport <PORT> -j ACCEPT${NC}"
echo -e "${YEL}    iptables-save > /etc/iptables/rules.v4${NC}"
echo ""
echo -e "${YEL}  To view rules:${NC}"
echo -e "${YEL}    iptables -L -n --line-numbers${NC}"
echo -e "${YEL}    iptables -t nat -L -n --line-numbers${NC}"
echo ""
echo -e "${YEL}  To restore pre-migration state (emergency rollback):${NC}"
echo -e "${YEL}    iptables-restore < ${SNAPSHOT_DIR}/iptables-v4-before.rules${NC}"
echo ""
