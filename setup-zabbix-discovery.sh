#!/usr/bin/env bash
# =============================================================================
# Zabbix Discovery Setup Script
# Creates a network discovery rule (agent + SNMP v1/2c) via the Zabbix API,
# and discovery actions to automatically add discovered hosts to host groups.
#
# Fixed settings:
#   Agent check  : port 10050, key system.uname
#   SNMPv2c      : port 161, community prompted
#   SNMPv1       : port 161, community prompted
#
# Templates are NOT assigned — apply them manually after discovery.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarkLFT/Scripts/main/setup-zabbix-discovery.sh \
#     -o /tmp/setup-zabbix-discovery.sh && bash /tmp/setup-zabbix-discovery.sh
# =============================================================================

set -uo pipefail

# --- Colour helpers ----------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        Zabbix Discovery Setup                        ║${RESET}"
    echo -e "${CYAN}${BOLD}║        Agent + SNMP v1/2c  •  community prompted      ║${RESET}"
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

# --- Dependency check --------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required but not installed"
if ! command -v jq >/dev/null 2>&1; then
    log_info "jq not found — installing..."
    apt-get install -y -q jq >/dev/null 2>&1 || die "Could not install jq — install it manually and re-run"
fi

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

# Pick from a numbered list — sets REPLY (name) and REPLY_ID (id)
pick_from_list() {
    local label="$1" json="$2" name_field="$3" id_field="$4"
    local count
    count=$(echo "$json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        REPLY=""; REPLY_ID=""; return 1
    fi
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
# ZABBIX API HELPERS
# =============================================================================

ZABBIX_URL=""
AUTH_TOKEN=""
API_ID=1

zabbix_api() {
    local method="$1" params="$2"

    # Zabbix 7.x: auth token is passed as Authorization: Bearer header, not in the request body
    local -a curl_args=(-s -X POST "${ZABBIX_URL}/api_jsonrpc.php"
        -H "Content-Type: application/json")
    [[ -n "$AUTH_TOKEN" ]] && curl_args+=(-H "Authorization: Bearer ${AUTH_TOKEN}")

    local response
    response=$(curl "${curl_args[@]}" \
        -d "{
            \"jsonrpc\": \"2.0\",
            \"method\": \"${method}\",
            \"params\": ${params},
            \"id\": ${API_ID}
        }" 2>/dev/null)

    ((API_ID++))

    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        local errmsg
        errmsg=$(echo "$response" | jq -r '.error.data // .error.message')
        echo "API_ERROR: ${errmsg}" >&2
        echo ""
        return 1
    fi

    echo "$response" | jq -r '.result'
}

# =============================================================================
# COLLECT CONFIGURATION
# =============================================================================

print_header

# --- Zabbix connection -------------------------------------------------------
print_section "Zabbix Server Connection"
REPLY=""
prompt_value "Zabbix server URL" "http://localhost/zabbix"
ZABBIX_URL="${REPLY%/}"

REPLY=""
prompt_value "API username" "Admin"
API_USER="$REPLY"

SECRET_REPLY=""
prompt_secret "API password"
API_PASS="$SECRET_REPLY"

log_info "Authenticating..."
AUTH_TOKEN=$(zabbix_api "user.login" "{\"username\": \"${API_USER}\", \"password\": \"${API_PASS}\"}")
if [[ -z "$AUTH_TOKEN" || "$AUTH_TOKEN" == "null" || "$AUTH_TOKEN" == API_ERROR* ]]; then
    die "Authentication failed — check URL and credentials"
fi
log_ok "Authenticated successfully"

# --- Select proxy ------------------------------------------------------------
print_section "Proxy"
log_info "Loading proxies..."
PROXIES_JSON=$(zabbix_api "proxy.get" '{"output": ["proxyid","name"]}')
if [[ -z "$PROXIES_JSON" || "$PROXIES_JSON" == "[]" ]]; then
    die "No proxies found — add a proxy in Zabbix UI first"
fi

pick_from_list "Select proxy for this discovery rule" "$PROXIES_JSON" ".name" ".proxyid" \
    || die "No proxies available"
PROXY_NAME="$REPLY"
PROXY_ID="$REPLY_ID"
log_ok "Selected: $PROXY_NAME"

# --- Discovery rule ----------------------------------------------------------
print_section "Discovery Rule"
REPLY=""
prompt_value "Discovery rule name" "Discover ${PROXY_NAME}"
RULE_NAME="$REPLY"

REPLY=""
prompt_value "IP range (e.g. 192.168.1.1-254 or 192.168.1.0/24)" ""
IP_RANGE="$REPLY"

REPLY=""
prompt_value "Scan interval (e.g. 1h, 30m)" "1h"
SCAN_DELAY="$REPLY"

REPLY=""
prompt_value "SNMP community string" "nmc"
SNMP_COMMUNITY="$REPLY"

# --- Host groups -------------------------------------------------------------
print_section "Host Groups"
log_info "Loading host groups..."
GROUPS_JSON=$(zabbix_api "hostgroup.get" '{"output": ["groupid","name"], "sortfield": "name"}')
if [[ -z "$GROUPS_JSON" || "$GROUPS_JSON" == "[]" ]]; then
    die "No host groups found — create host groups in Zabbix UI first"
fi

echo ""
echo -e "  ${BOLD}Agent host group${RESET}"
echo -e "  Applied when host responds to Zabbix agent check on port 10050."
echo ""
pick_from_list "Select group for agent hosts" "$GROUPS_JSON" ".name" ".groupid"
AGENT_GROUP_NAME="$REPLY"
AGENT_GROUP_ID="$REPLY_ID"
log_ok "Agent group: $AGENT_GROUP_NAME"

echo ""
echo -e "  ${BOLD}SNMP host group${RESET}"
echo -e "  Applied when host responds to SNMP check on port 161."
echo -e "  ${YELLOW}Can be the same group as above.${RESET}"
echo ""
pick_from_list "Select group for SNMP hosts" "$GROUPS_JSON" ".name" ".groupid"
SNMP_GROUP_NAME="$REPLY"
SNMP_GROUP_ID="$REPLY_ID"
log_ok "SNMP group: $SNMP_GROUP_NAME"

# --- Summary & confirm -------------------------------------------------------
print_section "Configuration Summary"
echo ""
echo -e "  ${BOLD}Discovery rule:${RESET}  $RULE_NAME"
echo -e "  ${BOLD}Proxy:${RESET}           $PROXY_NAME"
echo -e "  ${BOLD}IP range:${RESET}        $IP_RANGE"
echo -e "  ${BOLD}Interval:${RESET}        $SCAN_DELAY"
echo ""
echo -e "  ${BOLD}Checks (all in one rule):${RESET}"
echo -e "    Zabbix agent   port 10050"
echo -e "    SNMPv2c        port 161   community: ${SNMP_COMMUNITY}"
echo -e "    SNMPv1         port 161   community: ${SNMP_COMMUNITY}"
echo ""
echo -e "  ${BOLD}On discovery:${RESET}"
echo -e "    Agent hosts  → add to group: ${CYAN}$AGENT_GROUP_NAME${RESET}"
echo -e "    SNMP hosts   → add to group: ${CYAN}$SNMP_GROUP_NAME${RESET}"
echo -e "    ${YELLOW}Templates applied manually after discovery.${RESET}"
echo ""

prompt_confirm "Proceed" || { echo "Aborted."; exit 0; }

# =============================================================================
# CREATE DISCOVERY RULE
# =============================================================================

print_section "Creating Discovery Rule"

# dcheck types:
#   9  = Zabbix agent
#  10  = SNMPv1
#  11  = SNMPv2c
DCHECKS='[
    {
        "type": "9",
        "ports": "10050",
        "key_": "system.uname",
        "uniq": "1"
    },
    {
        "type": "11",
        "ports": "161",
        "snmp_community": "${SNMP_COMMUNITY}",
        "key_": "ifIndex.0",
        "uniq": "0"
    },
    {
        "type": "10",
        "ports": "161",
        "snmp_community": "${SNMP_COMMUNITY}",
        "key_": "ifIndex.0",
        "uniq": "0"
    }
]'

RULE_RESULT=$(zabbix_api "drule.create" "{
    \"name\": \"${RULE_NAME}\",
    \"iprange\": \"${IP_RANGE}\",
    \"delay\": \"${SCAN_DELAY}\",
    \"proxyid\": \"${PROXY_ID}\",
    \"status\": \"0\",
    \"dchecks\": ${DCHECKS}
}")

if [[ -z "$RULE_RESULT" || "$RULE_RESULT" == "null" ]]; then
    die "Failed to create discovery rule"
fi

RULE_ID=$(echo "$RULE_RESULT" | jq -r '.druleids[0]')
log_ok "Discovery rule created (ID: $RULE_ID)"

# Get dcheck IDs back from Zabbix so actions can reference them
DCHECKS_RESULT=$(zabbix_api "drule.get" "{
    \"output\": [\"druleid\"],
    \"selectDChecks\": [\"dcheckid\",\"type\"],
    \"druleids\": [\"${RULE_ID}\"]
}")

AGENT_DCHECK_ID=$(echo "$DCHECKS_RESULT" | jq -r '.[0].dchecks[] | select(.type == "9")  | .dcheckid')
SNMPV2_DCHECK_ID=$(echo "$DCHECKS_RESULT" | jq -r '.[0].dchecks[] | select(.type == "11") | .dcheckid')
SNMPV1_DCHECK_ID=$(echo "$DCHECKS_RESULT" | jq -r '.[0].dchecks[] | select(.type == "10") | .dcheckid')

# =============================================================================
# CREATE DISCOVERY ACTIONS
# =============================================================================

print_section "Creating Discovery Actions"

# operationtype values:
#   2 = Add host
#   4 = Add to host group

# --- Agent action ------------------------------------------------------------
# Condition: discovery rule = this rule AND dcheck = agent AND service UP
AGENT_ACTION_RESULT=$(zabbix_api "action.create" "{
    \"name\": \"Auto-add: ${RULE_NAME} — Agent hosts\",
    \"eventsource\": \"1\",
    \"status\": \"0\",
    \"filter\": {
        \"evaltype\": \"1\",
        \"conditions\": [
            {
                \"conditiontype\": \"18\",
                \"operator\": \"0\",
                \"value\": \"${RULE_ID}\"
            },
            {
                \"conditiontype\": \"19\",
                \"operator\": \"0\",
                \"value\": \"${AGENT_DCHECK_ID}\"
            },
            {
                \"conditiontype\": \"21\",
                \"operator\": \"0\",
                \"value\": \"1\"
            }
        ]
    },
    \"operations\": [
        {
            \"operationtype\": \"2\"
        },
        {
            \"operationtype\": \"4\",
            \"opgroup\": [{\"groupid\": \"${AGENT_GROUP_ID}\"}]
        }
    ]
}")

if [[ -n "$AGENT_ACTION_RESULT" && "$AGENT_ACTION_RESULT" != "null" ]]; then
    AGENT_ACTION_ID=$(echo "$AGENT_ACTION_RESULT" | jq -r '.actionids[0]')
    log_ok "Agent action created (ID: $AGENT_ACTION_ID)"
else
    log_warn "Agent discovery action could not be created — check Zabbix logs"
fi

# --- SNMP action -------------------------------------------------------------
# Condition: discovery rule = this rule AND (dcheck = SNMPv2c OR dcheck = SNMPv1) AND service UP
# evaltype 2 = OR logic for conditions
SNMP_ACTION_RESULT=$(zabbix_api "action.create" "{
    \"name\": \"Auto-add: ${RULE_NAME} — SNMP hosts\",
    \"eventsource\": \"1\",
    \"status\": \"0\",
    \"filter\": {
        \"evaltype\": \"0\",
        \"conditions\": [
            {
                \"conditiontype\": \"18\",
                \"operator\": \"0\",
                \"value\": \"${RULE_ID}\"
            },
            {
                \"conditiontype\": \"19\",
                \"operator\": \"0\",
                \"value\": \"${SNMPV2_DCHECK_ID}\"
            },
            {
                \"conditiontype\": \"19\",
                \"operator\": \"0\",
                \"value\": \"${SNMPV1_DCHECK_ID}\"
            },
            {
                \"conditiontype\": \"21\",
                \"operator\": \"0\",
                \"value\": \"1\"
            }
        ]
    },
    \"operations\": [
        {
            \"operationtype\": \"2\"
        },
        {
            \"operationtype\": \"4\",
            \"opgroup\": [{\"groupid\": \"${SNMP_GROUP_ID}\"}]
        }
    ]
}")

if [[ -n "$SNMP_ACTION_RESULT" && "$SNMP_ACTION_RESULT" != "null" ]]; then
    SNMP_ACTION_ID=$(echo "$SNMP_ACTION_RESULT" | jq -r '.actionids[0]')
    log_ok "SNMP action created (ID: $SNMP_ACTION_ID)"
else
    log_warn "SNMP discovery action could not be created — check Zabbix logs"
fi

# --- Logout ------------------------------------------------------------------
zabbix_api "user.logout" '{}' >/dev/null 2>&1

# =============================================================================
# FINAL SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║           Discovery Setup Complete ✔                 ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Rule:${RESET}     $RULE_NAME (ID: $RULE_ID)"
echo -e "  ${BOLD}Proxy:${RESET}    $PROXY_NAME"
echo -e "  ${BOLD}Range:${RESET}    $IP_RANGE"
echo -e "  ${BOLD}Interval:${RESET} $SCAN_DELAY"
echo ""
echo -e "  ${BOLD}Verify in Zabbix UI:${RESET}"
echo -e "  Rules:    ${CYAN}Configuration → Discovery${RESET}"
echo -e "  Actions:  ${CYAN}Configuration → Actions → Discovery actions${RESET}"
echo -e "  Results:  ${CYAN}Monitoring → Discovery${RESET}"
echo ""
echo -e "  ${YELLOW}First scan runs within $SCAN_DELAY — check Monitoring → Discovery for results.${RESET}"
echo -e "  ${YELLOW}Assign templates to discovered hosts manually once they appear.${RESET}"
echo ""
