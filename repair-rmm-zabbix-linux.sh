#!/usr/bin/env bash
# =============================================================================
# RMM / Zabbix Repair & Cleanup — Linux (Ubuntu / Debian)
#
# Diagnoses and repairs hosts left in a half-installed state by an interrupted
# or failed TacticalRMM agent or Zabbix Agent 2 install, and can strip either
# stack back to nothing so a clean install can follow.
#
# It never installs either agent — use the dedicated installers for that:
#   install-tacticalrmm-agent-linux.sh
#   install-zabbix-agent-linux-tactical-rmm.sh
#
# Actions:
#   report        Read-only diagnosis (default). Exit 0 = healthy/absent,
#                 1 = problems found — usable as a TacticalRMM check.
#   repair        Fix what can be fixed safely, then re-report.
#   clean-trmm    Remove all TacticalRMM agent components (including mesh)
#   clean-zabbix  Remove all Zabbix Agent 2 components
#   clean-all     Both of the above
#
# Safety:
#   - report is read-only and is the default; nothing is removed by accident.
#   - Every destructive action backs up all configuration to a timestamped
#     tarball under /var/backups first.
#   - A clean-* action refuses to run against a HEALTHY stack unless "force" is
#     given, so a stray scheduled run cannot wipe a working agent.
#   - Non-interactive runs must pass "yes" (or "force") explicitly to confirm.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/repair-rmm-zabbix-linux.sh \
#     -o /tmp/repair-rmm-zabbix-linux.sh && sudo bash /tmp/repair-rmm-zabbix-linux.sh
#
#   Via TacticalRMM (diagnosis only, as a check):
#   curl -fsSL .../repair-rmm-zabbix-linux.sh | sudo bash -s -- "report" "{{global.DiscordWebhook}}"
#
#   Via TacticalRMM (repair):
#   curl -fsSL .../repair-rmm-zabbix-linux.sh | sudo bash -s -- "repair" "{{global.DiscordWebhook}}" "yes"
#
# Arguments:
#   $1 = action (report|repair|clean-trmm|clean-zabbix|clean-all)  default: report
#   $2 = Discord webhook URL (optional)
#   $3 = "yes" to confirm a destructive action non-interactively,
#        "force" to also allow cleaning a stack that looks healthy
# =============================================================================

# Deliberately not using -e: this script probes a broken system, where a
# non-zero return from a check is normal input, not a failure. Every real
# failure is handled explicitly with || die / || warn.
set -uo pipefail

# --- Arguments ---------------------------------------------------------------
ACTION=$(echo "${1:-}" | tr -d "'" | tr '[:upper:]' '[:lower:]')
DISCORD_WEBHOOK=$(echo "${2:-}" | tr -d "'")
CONFIRM=$(echo "${3:-}" | tr -d "'" | tr '[:upper:]' '[:lower:]')

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        RMM / Zabbix Repair & Cleanup                 ║${RESET}"
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
log_bad()   { echo -e "  ${RED}✖${RESET}  $1"; }
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
    "footer": { "text": "RMM / Zabbix Repair - Linux" },
    "timestamp": "%s"
  }]
}' "$safe_title" "$safe_desc" "$color" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

    curl -s -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK" >/dev/null 2>&1 \
        || log_warn "Discord notification failed"
}

notify_failure() {
    local reason="$1"
    send_discord "❌ RMM / Zabbix Repair Failed" \
        "**Host:** \`${SYS_HOSTNAME:-$(hostname -f 2>/dev/null)}\`\n**IP:** \`${IP_ADDRESS:-$(hostname -I 2>/dev/null | awk '{print $1}')}\`\n**Reason:** ${reason}" \
        15158332
}

# --- Must run as root --------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash repair-rmm-zabbix-linux.sh"

# --- OS check ----------------------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect OS"
. /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] \
    || die "Unsupported OS: $ID (Ubuntu and Debian only)"

# --- System info -------------------------------------------------------------
SYS_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')

# --- Paths -------------------------------------------------------------------
RMM_BIN="/usr/local/bin/rmmagent"
RMM_CONF="/etc/tacticalagent"
RMM_UNIT="/etc/systemd/system/tacticalagent.service"
RMM_SVC="tacticalagent"
MESH_DIR="/opt/tacticalmesh"
MESH_BIN="${MESH_DIR}/meshagent"
MESH_SVC="meshagent"

ZBX_CONF="/etc/zabbix/zabbix_agent2.conf"
ZBX_CONF_D="/etc/zabbix/zabbix_agent2.d"
ZBX_PLUGINS_D="${ZBX_CONF_D}/plugins.d"
ZBX_SVC="zabbix-agent2"
ZBX_PKG="zabbix-agent2"

BACKUP_DIR="/var/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# --- Findings ----------------------------------------------------------------
# Each finding is "<stack>|<severity>|<message>"; repairs append to REPAIRS_DONE.
FINDINGS=()
REPAIRS_DONE=()
TRMM_STATE="unknown"
ZBX_STATE="unknown"

finding() { FINDINGS+=("$1|$2|$3"); }
repaired() { REPAIRS_DONE+=("$1"); log_ok "Repaired: $1"; }

# =============================================================================
# PROBE HELPERS
# =============================================================================

unit_exists() {
    local unit="$1"
    systemctl cat "${unit}.service" >/dev/null 2>&1 && return 0
    [[ -f "/etc/systemd/system/${unit}.service"  ]] && return 0
    [[ -f "/lib/systemd/system/${unit}.service"  ]] && return 0
    [[ -f "/usr/lib/systemd/system/${unit}.service" ]] && return 0
    return 1
}

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_failed() { [[ "$(systemctl is-failed "$1" 2>/dev/null)" == "failed" ]]; }

pkg_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}

pkg_present_broken() {
    # Present in dpkg but not fully installed (half-configured, unpacked, etc.)
    local status
    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ -n "$status" && "$status" != "install ok installed" ]]
}

# =============================================================================
# DIAGNOSE — TACTICALRMM
# =============================================================================

diagnose_trmm() {
    print_section "TacticalRMM Agent"

    local has_bin=0 has_conf=0 has_unit=0 bin_runs=0 conf_valid=0
    [[ -f "$RMM_BIN" ]] && has_bin=1
    [[ -f "$RMM_CONF" ]] && has_conf=1
    unit_exists "$RMM_SVC" && has_unit=1

    if [[ $has_bin -eq 1 ]]; then
        if [[ -x "$RMM_BIN" ]] && "$RMM_BIN" -version >/dev/null 2>&1; then
            bin_runs=1
            log_ok "Binary present and runs: $("$RMM_BIN" -version 2>/dev/null | head -1)"
        else
            log_bad "Binary present at $RMM_BIN but will not run (corrupt or wrong architecture)"
            finding "trmm" "broken" "rmmagent binary will not execute"
        fi
    else
        log_info "No agent binary at $RMM_BIN"
    fi

    if [[ $has_conf -eq 1 ]]; then
        if grep -q '"agentid"' "$RMM_CONF" 2>/dev/null; then
            conf_valid=1
            log_ok "Config present and contains an agent id"
        else
            log_bad "Config $RMM_CONF present but has no agent id — registration did not complete"
            finding "trmm" "partial" "agent config exists but is not registered"
        fi
    else
        log_info "No agent config at $RMM_CONF"
    fi

    if [[ $has_unit -eq 1 ]]; then
        if svc_active "$RMM_SVC"; then
            log_ok "Service ${RMM_SVC} is active"
        elif svc_failed "$RMM_SVC"; then
            log_bad "Service ${RMM_SVC} is in a failed state"
            finding "trmm" "broken" "tacticalagent service failed"
        else
            log_warn "Service ${RMM_SVC} exists but is not running"
            finding "trmm" "partial" "tacticalagent service not running"
        fi
    else
        log_info "No ${RMM_SVC} systemd unit"
    fi

    # --- Cross-checks: the combinations that mean "half installed" -----------
    if [[ $has_bin -eq 1 && $has_conf -eq 0 ]]; then
        finding "trmm" "partial" "binary installed but never registered (no $RMM_CONF)"
    fi
    if [[ $has_conf -eq 1 && $has_bin -eq 0 ]]; then
        finding "trmm" "broken" "config exists but the binary is missing — agent cannot run"
    fi
    if [[ $has_bin -eq 1 && $has_conf -eq 1 && $has_unit -eq 0 ]]; then
        finding "trmm" "repairable" "binary and config present but the systemd unit is missing"
    fi
    if [[ $has_unit -eq 1 && $has_bin -eq 0 ]]; then
        finding "trmm" "broken" "systemd unit exists but the binary is missing"
    fi

    # --- MeshCentral ---------------------------------------------------------
    if [[ -e "$MESH_BIN" ]]; then
        if svc_active "$MESH_SVC"; then
            log_ok "MeshCentral agent present and running"
        else
            log_warn "MeshCentral agent binary present but the service is not running"
            finding "trmm" "partial" "meshagent installed but not running"
        fi
    elif [[ -d "$MESH_DIR" ]]; then
        log_warn "Mesh directory $MESH_DIR exists but contains no meshagent binary"
        finding "trmm" "repairable" "empty $MESH_DIR left by a failed mesh install"
    else
        log_info "No MeshCentral agent (expected — the installer no longer installs it)"
    fi

    # --- Build leftovers -----------------------------------------------------
    local leftovers=()
    for p in /tmp/temp_rmmagent /tmp/rmmagent-master /tmp/rmmagent.tar.gz /tmp/golang.tar.gz; do
        [[ -e "$p" ]] && leftovers+=("$p")
    done
    while IFS= read -r d; do
        [[ -n "$d" ]] && leftovers+=("$d")
    done < <(find /tmp -maxdepth 1 \( -name 'trmm-install-*' -o -name 'trmm-update-*' \) 2>/dev/null)

    if [[ ${#leftovers[@]} -gt 0 ]]; then
        log_warn "Build leftovers in /tmp: ${#leftovers[@]} item(s)"
        finding "trmm" "repairable" "stale build leftovers in /tmp (${#leftovers[@]} item(s))"
    fi

    # --- Overall state -------------------------------------------------------
    if [[ $has_bin -eq 0 && $has_conf -eq 0 && $has_unit -eq 0 ]]; then
        TRMM_STATE="absent"
        log_info "TacticalRMM agent: not installed"
    elif [[ $bin_runs -eq 1 && $conf_valid -eq 1 && $has_unit -eq 1 ]] && svc_active "$RMM_SVC"; then
        TRMM_STATE="healthy"
        log_ok "TacticalRMM agent: healthy"
    else
        TRMM_STATE="partial"
        log_bad "TacticalRMM agent: PARTIAL / BROKEN"
    fi
}

# =============================================================================
# DIAGNOSE — ZABBIX
# =============================================================================

diagnose_zabbix() {
    print_section "Zabbix Agent 2"

    local has_pkg=0 has_conf=0 has_unit=0
    pkg_installed "$ZBX_PKG" && has_pkg=1
    [[ -f "$ZBX_CONF" ]] && has_conf=1
    unit_exists "$ZBX_SVC" && has_unit=1

    if [[ $has_pkg -eq 1 ]]; then
        log_ok "Package $ZBX_PKG installed ($(dpkg-query -W -f='${Version}' "$ZBX_PKG" 2>/dev/null))"
    elif pkg_present_broken "$ZBX_PKG"; then
        log_bad "Package $ZBX_PKG is present but not fully installed ($(dpkg-query -W -f='${Status}' "$ZBX_PKG" 2>/dev/null))"
        finding "zabbix" "repairable" "zabbix-agent2 package is half-installed"
    else
        log_info "Package $ZBX_PKG not installed"
    fi

    # dpkg-wide breakage blocks any further package work
    if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
        log_bad "dpkg reports packages in a broken state"
        finding "zabbix" "repairable" "dpkg database has broken packages (dpkg --audit)"
    fi

    # v1 agent left alongside v2 — they fight over port 10050
    if pkg_installed "zabbix-agent"; then
        log_bad "Legacy zabbix-agent (v1) is installed alongside Agent 2 — they conflict on port 10050"
        finding "zabbix" "repairable" "legacy zabbix-agent (v1) installed alongside zabbix-agent2"
    fi

    if [[ $has_conf -eq 1 ]]; then
        log_ok "Config present: $ZBX_CONF"
        local server server_active hostname_set
        server=$(grep -E '^Server='       "$ZBX_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
        server_active=$(grep -E '^ServerActive=' "$ZBX_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
        hostname_set=$(grep -E '^Hostname='      "$ZBX_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
        [[ -z "$server" ]]        && { log_bad "No Server= set in $ZBX_CONF";       finding "zabbix" "partial" "Server= not configured"; }
        [[ -z "$server_active" ]] && { log_bad "No ServerActive= set in $ZBX_CONF"; finding "zabbix" "partial" "ServerActive= not configured"; }
        [[ -z "$hostname_set" ]]  && { log_warn "No Hostname= set in $ZBX_CONF";    finding "zabbix" "partial" "Hostname= not configured"; }

        if [[ -d "$ZBX_PLUGINS_D" ]] && ! grep -qE "^Include=${ZBX_PLUGINS_D}/\*\.conf" "$ZBX_CONF" 2>/dev/null; then
            log_warn "plugins.d exists but is not included from the main config"
            finding "zabbix" "repairable" "missing Include for ${ZBX_PLUGINS_D}/*.conf"
        fi
    else
        log_info "No config at $ZBX_CONF"
        [[ $has_pkg -eq 1 ]] && finding "zabbix" "broken" "package installed but $ZBX_CONF is missing"
    fi

    # --- Plugin configs pointing at plugins that are not installed ----------
    # This is the classic crash loop: the agent loads plugins.d/*.conf and dies
    # when the referenced loadable plugin binary is absent.
    if [[ -d "$ZBX_PLUGINS_D" ]]; then
        local orphans=0 placeholders=0
        while IFS= read -r conf; do
            [[ -e "$conf" ]] || continue
            local base pkg
            base=$(basename "$conf" .conf)
            pkg="zabbix-agent2-plugin-${base}"
            if ! pkg_installed "$pkg"; then
                # Only flag plugins that ship as separate packages.
                if apt-cache show "$pkg" >/dev/null 2>&1; then
                    log_bad "Plugin config ${base}.conf present but $pkg is not installed"
                    orphans=$((orphans+1))
                fi
            fi
            if grep -q 'CHANGE_ME' "$conf" 2>/dev/null; then
                log_warn "Plugin config ${base}.conf still has placeholder credentials"
                placeholders=$((placeholders+1))
            fi
        done < <(find "$ZBX_PLUGINS_D" -maxdepth 1 -name '*.conf' 2>/dev/null)

        [[ $orphans -gt 0 ]] \
            && finding "zabbix" "repairable" "${orphans} plugin config(s) reference an uninstalled plugin (agent will crash)"
        [[ $placeholders -gt 0 ]] \
            && finding "zabbix" "partial" "${placeholders} plugin config(s) still contain CHANGE_ME placeholders"
    fi

    if [[ $has_unit -eq 1 ]]; then
        if svc_active "$ZBX_SVC"; then
            log_ok "Service ${ZBX_SVC} is active"
        elif svc_failed "$ZBX_SVC"; then
            log_bad "Service ${ZBX_SVC} is in a failed state"
            finding "zabbix" "broken" "zabbix-agent2 service failed"
        else
            log_warn "Service ${ZBX_SVC} exists but is not running"
            finding "zabbix" "partial" "zabbix-agent2 service not running"
        fi
    else
        log_info "No ${ZBX_SVC} systemd unit"
        [[ $has_pkg -eq 1 ]] && finding "zabbix" "broken" "package installed but no systemd unit"
    fi

    # --- Repo added but agent never installed -------------------------------
    local repo_files
    repo_files=$(find /etc/apt/sources.list.d -maxdepth 1 -name 'zabbix*' 2>/dev/null | head -5)
    if [[ -n "$repo_files" && $has_pkg -eq 0 ]]; then
        log_warn "Zabbix apt repository is configured but the agent is not installed"
        finding "zabbix" "partial" "zabbix apt repo present but zabbix-agent2 not installed"
    fi

    # --- Overall state -------------------------------------------------------
    if [[ $has_pkg -eq 0 && $has_conf -eq 0 && $has_unit -eq 0 && -z "$repo_files" ]]; then
        ZBX_STATE="absent"
        log_info "Zabbix Agent 2: not installed"
    elif [[ $has_pkg -eq 1 && $has_conf -eq 1 && $has_unit -eq 1 ]] && svc_active "$ZBX_SVC"; then
        ZBX_STATE="healthy"
        log_ok "Zabbix Agent 2: healthy"
    else
        ZBX_STATE="partial"
        log_bad "Zabbix Agent 2: PARTIAL / BROKEN"
    fi
}

# =============================================================================
# BACKUP
# =============================================================================

backup_configs() {
    local label="$1"
    local archive="${BACKUP_DIR}/rmm-zabbix-${label}-${TIMESTAMP}.tar.gz"
    local paths=()

    for p in "$RMM_CONF" "$RMM_UNIT" "$ZBX_CONF" "$ZBX_CONF_D"; do
        [[ -e "$p" ]] && paths+=("$p")
    done
    [[ -e "/etc/systemd/system/${ZBX_SVC}.service" ]] && paths+=("/etc/systemd/system/${ZBX_SVC}.service")

    if [[ ${#paths[@]} -eq 0 ]]; then
        log_info "Nothing to back up"
        return 0
    fi

    mkdir -p "$BACKUP_DIR" || die "Could not create $BACKUP_DIR"
    tar -czf "$archive" "${paths[@]}" 2>/dev/null \
        || die "Backup failed — refusing to continue with a destructive action"
    chmod 600 "$archive" 2>/dev/null || true
    log_ok "Backup written: $archive"
    BACKUP_PATH="$archive"
}

# =============================================================================
# REPAIR
# =============================================================================

write_trmm_unit() {
    cat >"$RMM_UNIT" <<'EOF'
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
}

do_repair() {
    print_section "Repairing"

    local acted=0

    # --- dpkg first: nothing else package-related can work until it is sane --
    if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
        log_info "Reconfiguring interrupted package installs..."
        if dpkg --configure -a >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get -f install -y -qq >/dev/null 2>&1; then
            repaired "dpkg database reconciled"; acted=1
        else
            log_warn "dpkg repair did not fully succeed — run 'dpkg --configure -a' manually"
        fi
    fi

    # --- TacticalRMM ---------------------------------------------------------
    if [[ -x "$RMM_BIN" ]] && [[ -f "$RMM_CONF" ]] && ! unit_exists "$RMM_SVC"; then
        log_info "Recreating the ${RMM_SVC} systemd unit..."
        write_trmm_unit
        systemctl daemon-reload >/dev/null 2>&1 || log_warn "daemon-reload failed"
        systemctl enable "$RMM_SVC" >/dev/null 2>&1 || log_warn "Could not enable ${RMM_SVC}"
        if systemctl restart "$RMM_SVC" >/dev/null 2>&1; then
            repaired "recreated and started the ${RMM_SVC} service"; acted=1
        else
            log_warn "Unit written but ${RMM_SVC} would not start — check: journalctl -u ${RMM_SVC} -n 50"
        fi
    fi

    if unit_exists "$RMM_SVC" && [[ -x "$RMM_BIN" ]] && [[ -f "$RMM_CONF" ]] && ! svc_active "$RMM_SVC"; then
        log_info "Starting ${RMM_SVC}..."
        if systemctl restart "$RMM_SVC" >/dev/null 2>&1 && sleep 2 && svc_active "$RMM_SVC"; then
            repaired "started the ${RMM_SVC} service"; acted=1
        else
            log_warn "${RMM_SVC} still will not start:"
            journalctl -u "$RMM_SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/      /'
        fi
    fi

    # Empty mesh dir left by the old installer's failed mesh install
    if [[ -d "$MESH_DIR" && ! -e "$MESH_BIN" ]]; then
        if rmdir "$MESH_DIR" 2>/dev/null || rm -rf "$MESH_DIR"; then
            repaired "removed the empty $MESH_DIR left by a failed mesh install"; acted=1
        fi
    fi

    # Build leftovers
    local removed=0
    for p in /tmp/temp_rmmagent /tmp/rmmagent-master /tmp/rmmagent.tar.gz /tmp/golang.tar.gz; do
        [[ -e "$p" ]] && { rm -rf "$p" && removed=$((removed+1)); }
    done
    while IFS= read -r d; do
        [[ -n "$d" ]] && { rm -rf "$d" && removed=$((removed+1)); }
    done < <(find /tmp -maxdepth 1 \( -name 'trmm-install-*' -o -name 'trmm-update-*' \) 2>/dev/null)
    [[ $removed -gt 0 ]] && { repaired "cleared ${removed} stale build leftover(s) from /tmp"; acted=1; }

    # --- Zabbix --------------------------------------------------------------
    # Disable plugin configs whose plugin package is missing — this is what puts
    # the agent into a crash loop after a partial install.
    if [[ -d "$ZBX_PLUGINS_D" ]]; then
        local disabled=0
        while IFS= read -r conf; do
            [[ -e "$conf" ]] || continue
            local base pkg
            base=$(basename "$conf" .conf)
            pkg="zabbix-agent2-plugin-${base}"
            if ! pkg_installed "$pkg" && apt-cache show "$pkg" >/dev/null 2>&1; then
                mv "$conf" "${conf}.disabled" 2>/dev/null \
                    && { log_info "Disabled ${base}.conf (plugin $pkg not installed)"; disabled=$((disabled+1)); }
            fi
        done < <(find "$ZBX_PLUGINS_D" -maxdepth 1 -name '*.conf' 2>/dev/null)
        [[ $disabled -gt 0 ]] && { repaired "disabled ${disabled} orphaned plugin config(s)"; acted=1; }
    fi

    # Missing Include for plugins.d
    if [[ -f "$ZBX_CONF" ]] && [[ -d "$ZBX_PLUGINS_D" ]] \
       && ! grep -qE "^Include=${ZBX_PLUGINS_D}/\*\.conf" "$ZBX_CONF" 2>/dev/null; then
        cp -a "$ZBX_CONF" "${ZBX_CONF}.bak" 2>/dev/null || log_warn "Could not back up $ZBX_CONF"
        printf '\nInclude=%s/*.conf\n' "$ZBX_PLUGINS_D" >> "$ZBX_CONF"
        repaired "added the plugins.d Include directive (backup: ${ZBX_CONF}.bak)"; acted=1
    fi

    if unit_exists "$ZBX_SVC" && pkg_installed "$ZBX_PKG" && [[ -f "$ZBX_CONF" ]] && ! svc_active "$ZBX_SVC"; then
        log_info "Starting ${ZBX_SVC}..."
        systemctl enable "$ZBX_SVC" >/dev/null 2>&1 || true
        if systemctl restart "$ZBX_SVC" >/dev/null 2>&1 && sleep 2 && svc_active "$ZBX_SVC"; then
            repaired "started the ${ZBX_SVC} service"; acted=1
        else
            log_warn "${ZBX_SVC} still will not start:"
            journalctl -u "$ZBX_SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/      /'
        fi
    fi

    [[ $acted -eq 0 ]] && log_info "Nothing to repair automatically"
    return 0
}

# =============================================================================
# CLEAN
# =============================================================================

clean_trmm() {
    print_section "Removing TacticalRMM Agent"

    if unit_exists "$RMM_SVC"; then
        systemctl stop    "$RMM_SVC" >/dev/null 2>&1 || log_warn "Could not stop ${RMM_SVC}"
        systemctl disable "$RMM_SVC" >/dev/null 2>&1 || true
        log_ok "Stopped and disabled ${RMM_SVC}"
    fi
    rm -f "$RMM_UNIT"

    # Mesh agent — uninstall properly if its binary is still there
    if [[ -x "$MESH_BIN" ]]; then
        env XAUTHORITY=foo DISPLAY=bar "$MESH_BIN" -uninstall >/dev/null 2>&1 || true
        sleep 1
    fi
    if unit_exists "$MESH_SVC"; then
        systemctl stop    "$MESH_SVC" >/dev/null 2>&1 || true
        systemctl disable "$MESH_SVC" >/dev/null 2>&1 || true
    fi
    rm -f "/lib/systemd/system/${MESH_SVC}.service" "/etc/systemd/system/${MESH_SVC}.service"
    rm -rf "$MESH_DIR"
    log_ok "Removed MeshCentral agent components"

    rm -f "$RMM_BIN"
    rm -rf "$RMM_CONF"
    rm -rf /tmp/temp_rmmagent /tmp/rmmagent-master /tmp/rmmagent.tar.gz /tmp/golang.tar.gz
    find /tmp -maxdepth 1 \( -name 'trmm-install-*' -o -name 'trmm-update-*' \) -exec rm -rf {} + 2>/dev/null

    systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Removed agent binary, config and build leftovers"
    log_info "The Go toolchain at /usr/local/go (if present) was left in place"
    REPAIRS_DONE+=("removed all TacticalRMM agent components")
}

clean_zabbix() {
    print_section "Removing Zabbix Agent 2"

    if unit_exists "$ZBX_SVC"; then
        systemctl stop    "$ZBX_SVC" >/dev/null 2>&1 || log_warn "Could not stop ${ZBX_SVC}"
        systemctl disable "$ZBX_SVC" >/dev/null 2>&1 || true
        log_ok "Stopped and disabled ${ZBX_SVC}"
    fi

    # Purge the agent and any loadable plugin packages
    local pkgs=()
    pkg_installed "$ZBX_PKG" && pkgs+=("$ZBX_PKG")
    pkg_installed "zabbix-agent" && pkgs+=("zabbix-agent")
    while IFS= read -r p; do
        [[ -n "$p" ]] && pkgs+=("$p")
    done < <(dpkg-query -W -f='${Package} ${Status}\n' 'zabbix-agent2-plugin-*' 2>/dev/null \
             | awk '$2=="install"{print $1}')

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        log_info "Purging: ${pkgs[*]}"
        if DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${pkgs[@]}" >/dev/null 2>&1; then
            log_ok "Purged ${#pkgs[@]} package(s)"
        else
            log_warn "apt purge reported an error — attempting dpkg --purge"
            dpkg --purge "${pkgs[@]}" >/dev/null 2>&1 || log_warn "dpkg --purge also failed"
        fi
    else
        log_info "No Zabbix agent packages installed"
    fi

    rm -rf "$ZBX_CONF" "$ZBX_CONF_D" /etc/zabbix
    rm -f "/etc/systemd/system/${ZBX_SVC}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Removed Zabbix configuration"

    # The apt repo is left in place deliberately — a reinstall needs it, and
    # removing it would force the installer to re-add and re-key the repo.
    log_info "The Zabbix apt repository was left configured (needed for reinstall)"
    REPAIRS_DONE+=("removed all Zabbix Agent 2 components")
}

# =============================================================================
# CONFIRMATION
# =============================================================================

confirm_destructive() {
    local what="$1" state="$2"

    if [[ "$state" == "healthy" && "$CONFIRM" != "force" ]]; then
        die "$what looks HEALTHY — refusing to remove it. Pass \"force\" as the third argument if you really mean to."
    fi

    if [[ "$CONFIRM" == "yes" || "$CONFIRM" == "force" ]]; then
        log_warn "Confirmation supplied via argument — proceeding"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        die "Refusing to run a destructive action non-interactively without confirmation. Pass \"yes\" as the third argument."
    fi

    echo ""
    echo -e "  ${RED}${BOLD}This will remove ${what} from ${SYS_HOSTNAME}.${RESET}"
    echo -e "  ${YELLOW}A configuration backup will be written to ${BACKUP_DIR} first.${RESET}"
    echo ""
    local ans
    read -rp "  Type REMOVE to continue: " ans
    [[ "$ans" == "REMOVE" ]] || { echo "Aborted."; exit 0; }
}

# =============================================================================
# SUMMARY
# =============================================================================

print_findings() {
    print_section "Summary"

    echo -e "  ${BOLD}Host:${RESET}            $SYS_HOSTNAME ($IP_ADDRESS)"
    echo -e "  ${BOLD}TacticalRMM:${RESET}     $(state_label "$TRMM_STATE")"
    echo -e "  ${BOLD}Zabbix Agent 2:${RESET}  $(state_label "$ZBX_STATE")"
    echo ""

    if [[ ${#FINDINGS[@]} -eq 0 ]]; then
        log_ok "No problems found"
        return 0
    fi

    echo -e "  ${BOLD}Findings:${RESET}"
    local f stack sev msg
    for f in "${FINDINGS[@]}"; do
        stack="${f%%|*}"
        sev=$(echo "$f" | cut -d'|' -f2)
        msg="${f##*|}"
        case "$sev" in
            broken)     echo -e "    ${RED}✖${RESET}  [${stack}] ${msg}" ;;
            repairable) echo -e "    ${YELLOW}⚙${RESET}  [${stack}] ${msg} ${CYAN}(auto-repairable)${RESET}" ;;
            *)          echo -e "    ${YELLOW}⚠${RESET}  [${stack}] ${msg}" ;;
        esac
    done
    return 1
}

state_label() {
    case "$1" in
        healthy) echo -e "${GREEN}healthy${RESET}" ;;
        absent)  echo -e "${CYAN}not installed${RESET}" ;;
        partial) echo -e "${RED}partial / broken${RESET}" ;;
        *)       echo -e "${YELLOW}unknown${RESET}" ;;
    esac
}

print_next_steps() {
    local need_trmm=0 need_zbx=0
    [[ "$TRMM_STATE" == "partial" || "$TRMM_STATE" == "absent" ]] && need_trmm=1
    [[ "$ZBX_STATE"  == "partial" || "$ZBX_STATE"  == "absent" ]] && need_zbx=1
    [[ $need_trmm -eq 0 && $need_zbx -eq 0 ]] && return 0

    echo ""
    echo -e "  ${BOLD}Next steps:${RESET}"
    if [[ $need_trmm -eq 1 ]]; then
        echo -e "  Reinstall the RMM agent:"
        echo -e "    ${CYAN}curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/install-tacticalrmm-agent-linux.sh \\${RESET}"
        echo -e "    ${CYAN}  -o /tmp/i.sh && sudo bash /tmp/i.sh${RESET}"
    fi
    if [[ $need_zbx -eq 1 ]]; then
        echo -e "  Reinstall the Zabbix agent (via TacticalRMM, with your site variables):"
        echo -e "    ${CYAN}install-zabbix-agent-linux-tactical-rmm.sh${RESET}"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

print_header

# --- Interactive action selection when no arguments were given ---------------
if [[ -z "$ACTION" ]]; then
    if [[ -t 0 ]]; then
        print_section "Action"
        echo "  1) Report only — diagnose, change nothing (default)"
        echo "  2) Repair      — fix what can be fixed safely"
        echo "  3) Remove the TacticalRMM agent"
        echo "  4) Remove the Zabbix agent"
        echo "  5) Remove both"
        echo ""
        read -rp "  Choice [1-5]: " choice
        case "${choice:-1}" in
            1) ACTION="report" ;;
            2) ACTION="repair" ;;
            3) ACTION="clean-trmm" ;;
            4) ACTION="clean-zabbix" ;;
            5) ACTION="clean-all" ;;
            *) die "Invalid choice" ;;
        esac
    else
        ACTION="report"
    fi
fi

case "$ACTION" in
    report|repair|clean-trmm|clean-zabbix|clean-all) ;;
    help|-h|--help)
        echo "  Usage: repair-rmm-zabbix-linux.sh [report|repair|clean-trmm|clean-zabbix|clean-all] [webhook] [yes|force]"
        exit 0 ;;
    *) die "Unknown action: $ACTION (expected report, repair, clean-trmm, clean-zabbix or clean-all)" ;;
esac

log_info "Action: $ACTION"

# --- Always diagnose first ---------------------------------------------------
diagnose_trmm
diagnose_zabbix

# --- Act ---------------------------------------------------------------------
case "$ACTION" in
    repair)
        do_repair
        FINDINGS=()
        diagnose_trmm
        diagnose_zabbix
        ;;
    clean-trmm)
        confirm_destructive "the TacticalRMM agent" "$TRMM_STATE"
        backup_configs "trmm"
        clean_trmm
        FINDINGS=(); diagnose_trmm; diagnose_zabbix
        ;;
    clean-zabbix)
        confirm_destructive "the Zabbix agent" "$ZBX_STATE"
        backup_configs "zabbix"
        clean_zabbix
        FINDINGS=(); diagnose_trmm; diagnose_zabbix
        ;;
    clean-all)
        CLEAN_ALL_STATE="partial"
        [[ "$TRMM_STATE" == "healthy" && "$ZBX_STATE" == "healthy" ]] && CLEAN_ALL_STATE="healthy"
        confirm_destructive "the TacticalRMM agent and the Zabbix agent" "$CLEAN_ALL_STATE"
        backup_configs "all"
        clean_trmm
        clean_zabbix
        FINDINGS=(); diagnose_trmm; diagnose_zabbix
        ;;
esac

# --- Report ------------------------------------------------------------------
if print_findings; then
    RESULT_OK=1
else
    RESULT_OK=0
fi
print_next_steps

# --- Notify ------------------------------------------------------------------
SUMMARY="**Host:** \`${SYS_HOSTNAME}\`\n**IP:** \`${IP_ADDRESS}\`\n**Action:** ${ACTION}\n**TacticalRMM:** ${TRMM_STATE}\n**Zabbix:** ${ZBX_STATE}"
if [[ ${#REPAIRS_DONE[@]} -gt 0 ]]; then
    SUMMARY="${SUMMARY}\n**Actions taken:**"
    for r in "${REPAIRS_DONE[@]}"; do SUMMARY="${SUMMARY}\n• ${r}"; done
fi
if [[ ${#FINDINGS[@]} -gt 0 ]]; then
    SUMMARY="${SUMMARY}\n**Outstanding:** ${#FINDINGS[@]} finding(s)"
fi
[[ -n "${BACKUP_PATH:-}" ]] && SUMMARY="${SUMMARY}\n**Backup:** \`${BACKUP_PATH}\`"

if [[ "$ACTION" == "report" ]]; then
    if [[ $RESULT_OK -eq 1 ]]; then
        send_discord "✅ RMM / Zabbix Check — Healthy" "$SUMMARY" 3066993
    else
        send_discord "⚠️ RMM / Zabbix Check — Problems Found" "$SUMMARY" 16776960
    fi
else
    if [[ $RESULT_OK -eq 1 ]]; then
        send_discord "✅ RMM / Zabbix ${ACTION} — Complete" "$SUMMARY" 3066993
    else
        send_discord "⚠️ RMM / Zabbix ${ACTION} — Issues Remain" "$SUMMARY" 16776960
    fi
fi

echo ""
if [[ $RESULT_OK -eq 1 ]]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║          No outstanding problems ✔                   ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
else
    echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}${BOLD}║          Problems remain — see findings above        ║${RESET}"
    echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
fi
echo ""

exit $(( RESULT_OK == 1 ? 0 : 1 ))
