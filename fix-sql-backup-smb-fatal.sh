#!/usr/bin/env bash
# =============================================================================
# fix-sql-backup-smb-fatal.sh
# Patches existing SQL Server Linux hosts:
#  1. Makes SMB mount failure non-fatal in the full backup script
#  2. Fixes duplicate logging in the cron job
#  3. Adds transaction log backups every 15 minutes (keeps log files trimmed)
#  4. Runs a full backup immediately
#
# Safe to run multiple times — skips steps already applied.
# Deploy via TacticalRMM as root.
# =============================================================================
set -euo pipefail

BACKUP_SCRIPT="/usr/local/sbin/mssql_backup.sh"
LOG_BACKUP_SCRIPT="/usr/local/sbin/mssql_logbackup.sh"
CRON_FILE="/etc/cron.d/mssql_backup"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

info()    { echo -e "[INFO]  $*"; }
success() { echo -e "${GRN}[OK]${NC}    $*"; }
warn()    { echo -e "${YEL}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root."
[[ -f "${BACKUP_SCRIPT}" ]] || die "Backup script not found: ${BACKUP_SCRIPT}"

# ── Extract variables from the existing full backup script ────────────────────
# These were baked in at install time — reuse them for the log backup script.
get_var() { grep "^${1}=" "${BACKUP_SCRIPT}" | head -1 | cut -d'=' -f2- | tr -d '"'; }

SQLCMD=$(get_var SQLCMD)
SA_PASSWORD=$(get_var SA_PASSWORD)
LOCAL_BACKUP_ROOT=$(get_var LOCAL_BACKUP_ROOT)
SMB_MOUNT=$(get_var SMB_MOUNT)
SMB_SHARE=$(get_var SMB_SHARE)
SMB_CRED_FILE=$(get_var SMB_CRED_FILE)
CLEANUP_HOURS=$(get_var CLEANUP_HOURS)

[[ -n "${SQLCMD}" ]]            || die "Could not extract SQLCMD from ${BACKUP_SCRIPT}"
[[ -n "${LOCAL_BACKUP_ROOT}" ]] || die "Could not extract LOCAL_BACKUP_ROOT from ${BACKUP_SCRIPT}"

# =============================================================================
# Patch 1: Make SMB mount failure non-fatal in full backup script
# =============================================================================
if grep -q 'SMB_OK=' "${BACKUP_SCRIPT}" 2>/dev/null; then
    success "Full backup script already patched (SMB non-fatal) — skipping."
else
    info "Backing up current script to ${BACKUP_SCRIPT}.bak..."
    cp -p "${BACKUP_SCRIPT}" "${BACKUP_SCRIPT}.bak"

    info "Patching: make SMB mount failure non-fatal..."

    sed -i '/# ── Ensure SMB share is mounted/,/^fi$/c\
# ── Ensure SMB share is mounted ──────────────────────────────────────────────\
SMB_OK=0\
if ! mountpoint -q "${SMB_MOUNT}" 2>/dev/null; then\
    log "SMB share not mounted — mounting now..."\
    mount -t cifs "${SMB_SHARE}" "${SMB_MOUNT}" \\\
        -o "credentials=${SMB_CRED_FILE},vers=3.0,file_mode=0770,dir_mode=0770" \\\
        \&\& SMB_OK=1 \\\
        || log "WARNING: Cannot mount SMB share ${SMB_SHARE} — local backup will still proceed."\
else\
    SMB_OK=1\
fi' "${BACKUP_SCRIPT}"

    sed -i 's|^# ── Copy backup tree to SMB share .*|if [[ ${SMB_OK} -eq 1 ]]; then\n\n# ── Copy backup tree to SMB share ────────────────────────────────────────────|' "${BACKUP_SCRIPT}"

    sed -i '/log "  Note: Remote cleanup encountered errors (non-fatal)."/a\
else\
    log "WARNING: SMB share unavailable — skipping remote sync. Backups exist locally only."\
fi' "${BACKUP_SCRIPT}"

    if grep -q 'SMB_OK=' "${BACKUP_SCRIPT}"; then
        success "Full backup script patched successfully."
    else
        warn "Patch may not have applied correctly — restoring backup."
        cp -p "${BACKUP_SCRIPT}.bak" "${BACKUP_SCRIPT}"
        die "Patch failed. Review ${BACKUP_SCRIPT} manually."
    fi
fi

# =============================================================================
# Patch 2: Fix duplicate logging in cron job
# =============================================================================
if [[ -f "${CRON_FILE}" ]] && grep -q '>> /var/log/mssql_backup.log' "${CRON_FILE}" 2>/dev/null; then
    info "Fixing cron job to remove duplicate logging..."
    sed -i 's|>> /var/log/mssql_backup.log 2>&1|>/dev/null 2>\&1|' "${CRON_FILE}"
    success "Cron job updated — script handles its own logging."
fi

# =============================================================================
# Patch 3: Add transaction log backup script + 15-min cron
# =============================================================================
if [[ -f "${LOG_BACKUP_SCRIPT}" ]]; then
    success "Log backup script already exists — skipping."
else
    info "Creating transaction log backup script: ${LOG_BACKUP_SCRIPT}..."

    cat > "${LOG_BACKUP_SCRIPT}" <<LOGBACKUPEOF
#!/usr/bin/env bash
# =============================================================================
# mssql_logbackup.sh
# Transaction log backup via Ola Hallengren's DatabaseBackup procedure.
#
# Runs every 15 minutes to keep transaction logs trimmed. Without regular log backups,
# databases in Full recovery model will have continuously growing log files.
# =============================================================================
set -euo pipefail

SQLCMD="${SQLCMD}"
SA_PASSWORD="${SA_PASSWORD}"
LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT}"
SMB_MOUNT="${SMB_MOUNT}"
SMB_SHARE="${SMB_SHARE}"
SMB_CRED_FILE="${SMB_CRED_FILE}"
CLEANUP_HOURS="${CLEANUP_HOURS}"
LOG_FILE="/var/log/mssql_backup.log"

log() { echo "\$(date '+%F %T') \$*" | tee -a "\${LOG_FILE}"; }

log "── Transaction Log Backup ─────────────────────────────────────────"

# ── Ensure SMB share is mounted ──────────────────────────────────────────────
SMB_OK=0
if ! mountpoint -q "\${SMB_MOUNT}" 2>/dev/null; then
    log "SMB share not mounted — mounting now..."
    mount -t cifs "\${SMB_SHARE}" "\${SMB_MOUNT}" \\
        -o "credentials=\${SMB_CRED_FILE},vers=3.0,file_mode=0770,dir_mode=0770" \\
        && SMB_OK=1 \\
        || log "WARNING: Cannot mount SMB share \${SMB_SHARE} — local log backup will still proceed."
else
    SMB_OK=1
fi

# ── Run Ola Hallengren's DatabaseBackup (LOG) ────────────────────────────────
log "Running DatabaseBackup for USER_DATABASES (LOG)..."

"\${SQLCMD}" \\
    -S localhost \\
    -U sa \\
    -P "\${SA_PASSWORD}" \\
    -C \\
    -d master \\
    -b \\
    -Q "EXECUTE dbo.DatabaseBackup
        @Databases   = 'USER_DATABASES',
        @Directory   = N'\${LOCAL_BACKUP_ROOT}',
        @BackupType  = 'LOG',
        @Compress    = 'Y',
        @Verify      = 'Y',
        @Checksum    = 'Y',
        @CleanupTime = \${CLEANUP_HOURS},
        @LogToTable  = 'Y';" \\
    >> "\${LOG_FILE}" 2>&1

BACKUP_RC=\$?
if [[ \${BACKUP_RC} -eq 0 ]]; then
    log "Log backup completed successfully."
else
    log "ERROR: Log backup returned exit code \${BACKUP_RC}."
    exit \${BACKUP_RC}
fi

# ── Sync to SMB share ────────────────────────────────────────────────────────
if [[ \${SMB_OK} -eq 1 ]]; then
    log "Syncing log backups to SMB share..."
    if command -v rsync &>/dev/null; then
        rsync -a \\
            --include='*.trn' \\
            --include='*/' \\
            --exclude='*' \\
            "\${LOCAL_BACKUP_ROOT}/" "\${SMB_MOUNT}/" \\
            >> "\${LOG_FILE}" 2>&1 \\
            && log "rsync (log) to SMB share completed." \\
            || log "WARNING: rsync (log) to SMB share failed — log backups are still local."
    else
        cp -r "\${LOCAL_BACKUP_ROOT}/." "\${SMB_MOUNT}/" \\
            >> "\${LOG_FILE}" 2>&1 \\
            && log "cp (log) to SMB share completed." \\
            || log "WARNING: cp (log) to SMB share failed — log backups are still local."
    fi
else
    log "WARNING: SMB share unavailable — skipping remote sync for log backups."
fi

log "── Transaction Log Backup complete ────────────────────────────────"
exit 0
LOGBACKUPEOF

    chmod +x "${LOG_BACKUP_SCRIPT}"
    success "Log backup script created: ${LOG_BACKUP_SCRIPT}"
fi

# ── Update cron to include 15-min log backups ─────────────────────────────────
if grep -q 'mssql_logbackup' "${CRON_FILE}" 2>/dev/null; then
    success "Log backup cron job already exists — skipping."
else
    info "Adding 15-min log backup to cron..."
    cat >> "${CRON_FILE}" <<CRONEOF

# SQL Server transaction LOG backup — every 15 minutes (keeps log files trimmed)
# Skips the 02:00 hour to avoid overlapping with the full backup.
*/15 0,1,3-23 * * * root ${LOG_BACKUP_SCRIPT} >/dev/null 2>&1
CRONEOF
    success "Log backup cron job added: every 15 min (except 02:00)."
fi

# =============================================================================
# Run backups immediately
# =============================================================================
info "Running full backup now..."
if "${BACKUP_SCRIPT}" >/dev/null 2>&1; then
    success "Full backup completed successfully."
else
    RC=$?
    warn "Full backup exited with code ${RC} — check /var/log/mssql_backup.log"
fi

info "Running log backup now..."
if "${LOG_BACKUP_SCRIPT}" >/dev/null 2>&1; then
    success "Log backup completed successfully."
else
    RC=$?
    warn "Log backup exited with code ${RC} — check /var/log/mssql_backup.log"
fi

success "All patches applied."
