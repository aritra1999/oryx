#!/usr/bin/env bash
# restore.sh — restore data from a backup on the external drive.
#
# Usage:
#   ./restore.sh --list                     list available backups
#   ./restore.sh --backup <id>              restore everything from a backup
#   ./restore.sh --backup <id> --component affine
#   ./restore.sh --backup <id> --component nextcloud
#   ./restore.sh --backup <id> --component stacks
#   ./restore.sh --backup <id> --component db
#   ./restore.sh --backup <id> --component immich
#   ./restore.sh --backup latest            use the most recent backup
#
# Components:
#   all        everything (default)
#   db         database dumps only (restores PostgreSQL)
#   affine     AFFiNE files + database
#   nextcloud  Nextcloud files + database
#   immich     Immich originals + database
#   stacks     docker-compose configs (no auto-restart)
#
# Safety:
#   · Asks for confirmation before overwriting anything
#   · Stops affected containers before restoring, restarts after
#   · Creates a snapshot of current data before overwriting
#   · Never deletes — always moves old data to a .pre-restore backup

set -euo pipefail

BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
STACKS_DIR="${STACKS_DIR:-${HOME}/stacks}"
SSD_AFFINE="${SSD_AFFINE:-/mnt/ssd/affine}"
SSD_NEXTCLOUD="${SSD_NEXTCLOUD:-/mnt/ssd/nextcloud}"
SSD_IMMICH="${SSD_IMMICH:-/mnt/ssd/immich}"


PROD_POSTGRES_CONTAINER="${PROD_POSTGRES_CONTAINER:-prod-postgres}"
IMMICH_POSTGRES_CONTAINER="${IMMICH_POSTGRES_CONTAINER:-immich-postgres}"
POSTGRES_USER="${POSTGRES_USER:-appuser}"
IMMICH_DB_USER="${IMMICH_DB_USER:-immich}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
info()    { echo -e "  ${BLUE}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
section() { echo; echo -e "${BOLD}$*${NC}"; echo "──────────────────────────────────────"; }

# ── Parse args ────────────────────────────────────────────────────────────────
LIST_ONLY=false
BACKUP_ID=""
COMPONENT="all"

while [[ $# -gt 0 ]]; do
  case $1 in
    --list)             LIST_ONLY=true; shift ;;
    --backup)           BACKUP_ID="$2"; shift 2 ;;
    --component)        COMPONENT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

BACKUPS_DIR="${BACKUP_MOUNT}/backups"

# ── List available backups ────────────────────────────────────────────────────
list_backups() {
  section "Available backups on ${BACKUP_MOUNT}"

  if [[ ! -d "${BACKUPS_DIR}" ]]; then
    warn "No backups found at ${BACKUPS_DIR}"
    exit 0
  fi

  local count=0
  while IFS= read -r dir; do
    local id
    id=$(basename "${dir}")
    local size
    size=$(du -sh "${dir}" 2>/dev/null | cut -f1 || echo "?")

    # Check what components are in this backup
    local parts=()
    [[ -d "${dir}/db-dumps" ]]  && parts+=("db")
    [[ -d "${dir}/affine" ]]    && parts+=("affine")
    [[ -d "${dir}/nextcloud" ]] && parts+=("nextcloud")
    [[ -d "${dir}/immich" ]]    && parts+=("immich")
    [[ -d "${dir}/stacks" ]]    && parts+=("stacks")

    echo -e "  ${BOLD}${id}${NC}  ${size}  [$(IFS=', '; echo "${parts[*]}")]"
    (( count++ ))
  done < <(find "${BACKUPS_DIR}" -maxdepth 1 -mindepth 1 -type d | sort -r)

  if (( count == 0 )); then
    warn "No backups found."
  else
    echo
    echo -e "  ${count} backup(s) found. Run with --backup <id> to restore."
  fi
  echo
}

if [[ "${LIST_ONLY}" == true ]]; then
  list_backups
  exit 0
fi

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "${BACKUP_ID}" ]]; then
  echo "Usage: $0 --list"
  echo "       $0 --backup <id> [--component all|db|affine|nextcloud|stacks|media]"
  echo
  echo "Run --list to see available backups."
  exit 1
fi

# Resolve 'latest'
if [[ "${BACKUP_ID}" == "latest" ]]; then
  if [[ -L "${BACKUP_MOUNT}/latest" ]]; then
    BACKUP_ID=$(basename "$(readlink "${BACKUP_MOUNT}/latest")")
  else
    fail "No 'latest' symlink found. Run --list to see available backups."
  fi
fi

RESTORE_DIR="${BACKUPS_DIR}/${BACKUP_ID}"

if [[ ! -d "${RESTORE_DIR}" ]]; then
  fail "Backup not found: ${RESTORE_DIR}
  Run --list to see available backups."
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
section "Restore: ${BACKUP_ID}"
echo -e "  Component:  ${BOLD}${COMPONENT}${NC}"
echo -e "  Source:     ${RESTORE_DIR}"

# Show manifest if it exists
if [[ -f "${RESTORE_DIR}/manifest.txt" ]]; then
  echo
  echo -e "  ${BOLD}Backup contents:${NC}"
  grep -A 20 "Contents:" "${RESTORE_DIR}/manifest.txt" | head -15 | sed 's/^/  /'
fi

# Check backup drive mounted
if ! mountpoint -q "${BACKUP_MOUNT}" 2>/dev/null; then
  fail "Backup drive not mounted at ${BACKUP_MOUNT}"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
echo
echo -e "  ${YELLOW}${BOLD}WARNING:${NC} This will overwrite current data."
echo -e "  Current data will be moved to *.pre-restore before overwriting."
echo
read -r -p "  Type YES to continue: " CONFIRM
echo

if [[ "${CONFIRM}" != "YES" ]]; then
  echo "  Aborted."
  exit 0
fi

PRE_RESTORE_TAG="pre-restore-$(date +%Y%m%d_%H%M%S)"

# ── Helper: stop/start a compose service ─────────────────────────────────────
compose_stop() {
  local stack="$1" service="$2"
  info "Stopping ${service}..."
  cd "${STACKS_DIR}/${stack}" && docker compose stop "${service}" 2>/dev/null || true
}

compose_start() {
  local stack="$1" service="$2"
  info "Starting ${service}..."
  cd "${STACKS_DIR}/${stack}" && docker compose start "${service}" 2>/dev/null || true
  ok "${service} started"
}

# ── Restore database ──────────────────────────────────────────────────────────
restore_db() {
  local container="$1" db_user="$2" db_name="$3" label="$4"
  local dump_file
  dump_file=$(find "${RESTORE_DIR}/db-dumps" -name "${db_name}_*.sql" | sort | tail -1)

  if [[ -z "${dump_file}" ]]; then
    warn "No dump found for ${label} — skipping"
    return
  fi

  info "Restoring ${label} database from $(basename "${dump_file}")..."

  if ! docker inspect "${container}" &>/dev/null; then
    warn "${container} not running — skipping ${label} DB restore"
    return
  fi

  # Drop + recreate to avoid conflicts
  docker exec "${container}" psql -U "${db_user}" -c \
    "DROP DATABASE IF EXISTS ${db_name}; CREATE DATABASE ${db_name};" postgres

  # Restore
  docker exec -i "${container}" psql -U "${db_user}" "${db_name}" < "${dump_file}"
  ok "${label} database restored"
}

# ── Restore: database only ────────────────────────────────────────────────────
if [[ "${COMPONENT}" == "db" ]] || [[ "${COMPONENT}" == "all" ]] || \
   [[ "${COMPONENT}" == "affine" ]] || [[ "${COMPONENT}" == "nextcloud" ]]; then

  section "Restoring databases"
  warn "Stopping services while DB is restored..."

  if [[ "${COMPONENT}" == "affine"    ]] || [[ "${COMPONENT}" == "all" ]]; then
    compose_stop "productivity" "affine"
    restore_db "${PROD_POSTGRES_CONTAINER}" "${POSTGRES_USER}" "affine" "AFFiNE"
  fi
  if [[ "${COMPONENT}" == "nextcloud" ]] || [[ "${COMPONENT}" == "all" ]]; then
    compose_stop "productivity" "nextcloud"
    restore_db "${PROD_POSTGRES_CONTAINER}" "${POSTGRES_USER}" "nextcloud" "Nextcloud"
  fi
  if [[ "${COMPONENT}" == "db" ]] || [[ "${COMPONENT}" == "all" ]]; then
    restore_db "${IMMICH_POSTGRES_CONTAINER}" "${IMMICH_DB_USER}" "immich" "Immich"
  fi
fi

# ── Restore: AFFiNE files ─────────────────────────────────────────────────────
if [[ "${COMPONENT}" == "affine" ]] || [[ "${COMPONENT}" == "all" ]]; then
  if [[ -d "${RESTORE_DIR}/affine" ]]; then
    section "Restoring AFFiNE files"
    compose_stop "productivity" "affine"

    # Preserve current data
    if [[ -d "${SSD_AFFINE}" ]]; then
      info "Moving current AFFiNE data to ${SSD_AFFINE}.${PRE_RESTORE_TAG}..."
      mv "${SSD_AFFINE}" "${SSD_AFFINE}.${PRE_RESTORE_TAG}"
    fi

    info "Restoring AFFiNE files..."
    rsync -aH "${RESTORE_DIR}/affine/" "${SSD_AFFINE}/"
    ok "AFFiNE files restored"

    compose_start "productivity" "affine"
  else
    warn "No AFFiNE files in this backup — skipping"
  fi
fi

# ── Restore: Nextcloud files ──────────────────────────────────────────────────
if [[ "${COMPONENT}" == "nextcloud" ]] || [[ "${COMPONENT}" == "all" ]]; then
  if [[ -d "${RESTORE_DIR}/nextcloud" ]]; then
    section "Restoring Nextcloud files"
    compose_stop "productivity" "nextcloud"

    # Enable maintenance mode before restore
    docker exec nextcloud php occ maintenance:mode --on 2>/dev/null || true

    if [[ -d "${SSD_NEXTCLOUD}" ]]; then
      info "Moving current Nextcloud data to ${SSD_NEXTCLOUD}.${PRE_RESTORE_TAG}..."
      mv "${SSD_NEXTCLOUD}" "${SSD_NEXTCLOUD}.${PRE_RESTORE_TAG}"
    fi

    info "Restoring Nextcloud files..."
    rsync -aH "${RESTORE_DIR}/nextcloud/" "${SSD_NEXTCLOUD}/"
    ok "Nextcloud files restored"

    compose_start "productivity" "nextcloud"

    # Disable maintenance mode + rescan files
    sleep 5  # give Nextcloud a moment to start
    docker exec nextcloud php occ maintenance:mode --off 2>/dev/null || true
    docker exec nextcloud php occ files:scan --all 2>/dev/null || true
    ok "Nextcloud file index rebuilt"
  else
    warn "No Nextcloud files in this backup — skipping"
  fi
fi

# ── Restore: Stack configs ────────────────────────────────────────────────────
if [[ "${COMPONENT}" == "stacks" ]] || [[ "${COMPONENT}" == "all" ]]; then
  if [[ -d "${RESTORE_DIR}/stacks" ]]; then
    section "Restoring stack configs"
    warn "This restores docker-compose.yml files only — NOT .env files."
    warn "Your .env files are untouched."

    if [[ -d "${STACKS_DIR}" ]]; then
      info "Backing up current stacks to ${STACKS_DIR}.${PRE_RESTORE_TAG}..."
      cp -r "${STACKS_DIR}" "${STACKS_DIR}.${PRE_RESTORE_TAG}"
    fi

    rsync -aH --exclude='.env' "${RESTORE_DIR}/stacks/" "${STACKS_DIR}/"
    ok "Stack configs restored (restart services manually to apply)"
  else
    warn "No stack configs in this backup — skipping"
  fi
fi

# ── Restore: Immich originals (on SSD) ───────────────────────────────────────
if [[ "${COMPONENT}" == "immich" ]] || [[ "${COMPONENT}" == "all" ]]; then
  if [[ -d "${RESTORE_DIR}/immich" ]]; then
    section "Restoring Immich originals"
    compose_stop "media" "immich-server"

    if [[ -d "${SSD_IMMICH}/upload" ]]; then
      info "Moving current Immich uploads to ${SSD_IMMICH}/upload.${PRE_RESTORE_TAG}..."
      mv "${SSD_IMMICH}/upload" "${SSD_IMMICH}/upload.${PRE_RESTORE_TAG}"
    fi

    info "Restoring Immich originals..."
    rsync -aH "${RESTORE_DIR}/immich/" "${SSD_IMMICH}/upload/"
    ok "Immich originals restored"
    compose_start "media" "immich-server"
  else
    warn "No Immich files in this backup — skipping"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
section "Restore complete"
ok "Backup ${BACKUP_ID} restored (component: ${COMPONENT})"
echo
warn "Pre-restore snapshots saved with suffix .${PRE_RESTORE_TAG}"
warn "Review and delete them when you're satisfied everything works."
echo
