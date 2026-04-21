#!/usr/bin/env bash
# =============================================================================
# Harbor Registry — Automated Backup Script
# =============================================================================
# Purpose:  Creates consistent backups of Harbor database, registry blobs,
#           and configuration files. Syncs to Hetzner Storage Box via rclone.
#
# Usage:    ./harbor-backup.sh [--dry-run]
# Schedule: Add to crontab — recommended daily at 02:00 UTC:
#           0 2 * * * /opt/harbor-registry/harbor-backup.sh >> /var/log/harbor-backup.log 2>&1
#
# Prerequisites:
#   - rclone configured with a remote named "hetzner-storagebox"
#   - Sufficient local disk space for temporary backup files
#   - This script must run as root or with docker permissions
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HARBOR_COMPOSE_DIR="/opt/harbor-registry"
HARBOR_DATA_DIR="/opt/harbor-registry"
BACKUP_BASE_DIR="/opt/harbor-backups"
RCLONE_REMOTE="hetzner-storagebox"
RCLONE_BUCKET="harbor-backups"
LOCAL_RETENTION_DAYS=7
REMOTE_RETENTION_DAYS=30
DRY_RUN=false
DATE_STAMP=$(date +%F_%H%M%S)
BACKUP_DIR="${BACKUP_BASE_DIR}/${DATE_STAMP}"
LOG_PREFIX="[harbor-backup]"

# Parse arguments
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "${LOG_PREFIX} Running in DRY-RUN mode — no changes will be made."
fi

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------
log() {
    echo "${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    log "ERROR: $*"
    # Attempt to restart services if they were stopped
    restart_services
    exit 1
}

stop_services() {
    log "Stopping harbor-core and harbor-jobservice for consistent backup..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        cd "${HARBOR_COMPOSE_DIR}"
        docker compose stop harbor-core harbor-jobservice || true
    fi
}

restart_services() {
    log "Restarting harbor-core and harbor-jobservice..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        cd "${HARBOR_COMPOSE_DIR}"
        docker compose start harbor-core harbor-jobservice || true
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------
log "Starting Harbor backup — ${DATE_STAMP}"

# Verify docker is accessible
if ! docker info >/dev/null 2>&1; then
    error_exit "Docker is not accessible. Run as root or add user to docker group."
fi

# Verify rclone is installed
if ! command -v rclone >/dev/null 2>&1; then
    error_exit "rclone is not installed. Install via: apt install rclone"
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"
log "Backup directory: ${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# Phase 1: Stop Services for Consistency
# ---------------------------------------------------------------------------
# Stopping core and jobservice ensures no writes occur during pg_dump.
# The registry service stays running to avoid disrupting in-progress pulls
# (reads are safe during backup). Pushes will queue and resume after restart.
stop_services

# ---------------------------------------------------------------------------
# Phase 2: Database Backup
# ---------------------------------------------------------------------------
log "Dumping PostgreSQL database..."
if [[ "${DRY_RUN}" == "false" ]]; then
    docker exec harbor-db pg_dumpall -U postgres \
        | gzip > "${BACKUP_DIR}/harbor-db-${DATE_STAMP}.sql.gz" \
        || error_exit "Database dump failed"
    
    DB_SIZE=$(du -sh "${BACKUP_DIR}/harbor-db-${DATE_STAMP}.sql.gz" | cut -f1)
    log "Database dump complete: ${DB_SIZE}"
else
    log "[DRY-RUN] Would dump PostgreSQL via pg_dumpall"
fi

# ---------------------------------------------------------------------------
# Phase 3: Registry Data Backup
# ---------------------------------------------------------------------------
# Registry blobs can be very large. We use tar with gzip compression.
# For incremental backups, consider switching to restic or borgbackup.
log "Archiving registry blob storage..."
if [[ "${DRY_RUN}" == "false" ]]; then
    # Use nice/ionice to prevent I/O starvation on the 2 vCPU server
    nice -n 19 ionice -c 3 \
        tar -czf "${BACKUP_DIR}/harbor-registry-data-${DATE_STAMP}.tar.gz" \
        -C "${HARBOR_DATA_DIR}" \
        --exclude='*.tmp' \
        harbor_registry_data 2>/dev/null \
        || log "WARNING: Registry data archive had non-fatal errors (some files may have changed during backup)"
    
    REGISTRY_SIZE=$(du -sh "${BACKUP_DIR}/harbor-registry-data-${DATE_STAMP}.tar.gz" 2>/dev/null | cut -f1)
    log "Registry data archive complete: ${REGISTRY_SIZE}"
else
    log "[DRY-RUN] Would archive registry blob storage"
fi

# ---------------------------------------------------------------------------
# Phase 4: Configuration Backup
# ---------------------------------------------------------------------------
log "Backing up configuration files..."
if [[ "${DRY_RUN}" == "false" ]]; then
    mkdir -p "${BACKUP_DIR}/config"
    
    # Docker Compose and environment
    cp "${HARBOR_COMPOSE_DIR}/docker-compose.yml" "${BACKUP_DIR}/config/" 2>/dev/null || true
    cp "${HARBOR_COMPOSE_DIR}/.env" "${BACKUP_DIR}/config/env.backup" 2>/dev/null || true
    
    # Harbor config directory (contains all service configs)
    if [[ -d "${HARBOR_COMPOSE_DIR}/common/config" ]]; then
        cp -r "${HARBOR_COMPOSE_DIR}/common/config" "${BACKUP_DIR}/config/harbor-config" 2>/dev/null || true
    fi
    
    log "Configuration backup complete"
else
    log "[DRY-RUN] Would copy configuration files"
fi

# ---------------------------------------------------------------------------
# Phase 5: Restart Services
# ---------------------------------------------------------------------------
restart_services

# ---------------------------------------------------------------------------
# Phase 6: Weekly PostgreSQL VACUUM
# ---------------------------------------------------------------------------
# VACUUM reclaims storage from dead tuples and updates planner statistics.
# Running weekly is sufficient for Harbor's write patterns (mostly reads).
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
if [[ "${DAY_OF_WEEK}" == "7" ]]; then
    log "Sunday — running PostgreSQL VACUUM ANALYZE..."
    if [[ "${DRY_RUN}" == "false" ]]; then
        docker exec harbor-db vacuumdb -U postgres -d registry -v --analyze 2>&1 \
            | tail -5 \
            || log "WARNING: VACUUM had non-fatal errors"
        log "VACUUM complete"
    else
        log "[DRY-RUN] Would run vacuumdb on registry database"
    fi
fi

# ---------------------------------------------------------------------------
# Phase 7: Sync to Hetzner Storage Box
# ---------------------------------------------------------------------------
log "Syncing backup to Hetzner Storage Box..."
if [[ "${DRY_RUN}" == "false" ]]; then
    rclone sync \
        "${BACKUP_DIR}/" \
        "${RCLONE_REMOTE}:${RCLONE_BUCKET}/${DATE_STAMP}/" \
        --checksum \
        --verbose \
        --transfers 4 \
        --checkers 8 \
        --retries 3 \
        --low-level-retries 10 \
        || error_exit "rclone sync to Hetzner Storage Box failed"
    
    log "Remote sync complete"
else
    log "[DRY-RUN] Would sync to ${RCLONE_REMOTE}:${RCLONE_BUCKET}/${DATE_STAMP}/"
fi

# ---------------------------------------------------------------------------
# Phase 8: Retention Cleanup
# ---------------------------------------------------------------------------
# Local: keep 7 days to allow quick restores
log "Cleaning up local backups older than ${LOCAL_RETENTION_DAYS} days..."
if [[ "${DRY_RUN}" == "false" ]]; then
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -mtime +${LOCAL_RETENTION_DAYS} \
        -exec rm -rf {} + 2>/dev/null || true
    log "Local cleanup complete"
else
    log "[DRY-RUN] Would delete local backups older than ${LOCAL_RETENTION_DAYS} days"
fi

# Remote: keep 30 days for compliance and disaster recovery
log "Cleaning up remote backups older than ${REMOTE_RETENTION_DAYS} days..."
if [[ "${DRY_RUN}" == "false" ]]; then
    rclone delete \
        --min-age "${REMOTE_RETENTION_DAYS}d" \
        "${RCLONE_REMOTE}:${RCLONE_BUCKET}/" \
        --verbose \
        || log "WARNING: Remote cleanup had errors (non-fatal)"
    
    # Remove empty directories left after file deletion
    rclone rmdirs \
        "${RCLONE_REMOTE}:${RCLONE_BUCKET}/" \
        --leave-root \
        || true
    
    log "Remote cleanup complete"
else
    log "[DRY-RUN] Would delete remote backups older than ${REMOTE_RETENTION_DAYS} days"
fi

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
CMD="${1:-help}"

case "${CMD}" in
  backup)  cmd_backup  ;;
  gc)      cmd_gc      ;;
  vacuum)  cmd_vacuum  ;;
  health)  cmd_health  ;;
  upgrade) cmd_upgrade "$@" ;;
  help|*)
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  backup           Full backup: DB dump + registry tar + rclone sync"
    echo "  gc               Manual garbage collection (delete untagged blobs)"
    echo "  vacuum           PostgreSQL VACUUM ANALYZE on registry database"
    echo "  health           API health check + container status"
    echo "  upgrade <v>      Pre-flight backup + rolling update to version <v>"
    echo ""
    echo "Examples:"
    echo "  $0 backup"
    echo "  $0 upgrade v2.12.1"
    echo "  $0 gc"
    echo ""
    ;;
esac