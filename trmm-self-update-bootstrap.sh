#!/usr/bin/env bash
# =============================================================================
# TacticalRMM Linux Agent Self-Update — Bootstrap
#
# Paste this into TacticalRMM (Settings → Script Manager → New → Shell) to run
# the Linux agent self-update across your fleet. Set the script argument to
# {{global.DiscordWebhook}} for an optional notification.
#
# Why a bootstrap (and not a plain curl | bash)?
#   The update restarts the `tacticalagent` service — the very service that runs
#   this script. A script launched by the agent lives in the agent's systemd
#   cgroup, so stopping the agent (KillMode=control-group) would kill the update
#   mid-run and could leave the agent down. We launch the updater in a detached
#   transient unit (systemd-run) so it survives the restart, and return
#   immediately so TacticalRMM records success before the agent stops.
#
# The detached updater pins HOME/GOCACHE so `go build` works in the stripped
# systemd unit environment. Follow progress on the host with:
#   journalctl -u trmm-self-update -f
#
# Runs as root via the agent — no sudo needed.
# =============================================================================

set -uo pipefail

URL="https://raw.githubusercontent.com/MarkLFT/Scripts/main/update-tacticalrmm-agent-linux.sh"
SCRIPT="/tmp/update-trmm-agent-linux.sh"
UNIT="trmm-self-update"

command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run required (systemd host expected)"; exit 1; }
curl -fsSL "$URL" -o "$SCRIPT" || { echo "Download of updater failed"; exit 1; }

# Clear any stale unit from a previous run, then launch detached in its own cgroup
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
systemd-run --collect --unit="$UNIT" /bin/bash "$SCRIPT" "$@" \
    || { echo "Failed to launch detached updater"; exit 1; }

echo "Update launched detached as '$UNIT'. It will recompile and restart the agent."
echo "Follow on the host with: journalctl -u $UNIT -f"
