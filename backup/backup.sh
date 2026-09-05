#!/usr/bin/env bash
# backup.sh — back up all important server data to the external backup drive.
#
# Usage:
#   ./backup.sh                      full backup
#   ./backup.sh --dry-run            show what would be backed up, don't write
#   ./backup.sh --only-db            only dump databases, skip file sync
#
# What gets backed up:
#   · PostgreSQL dumps (AFFiNE, Nextcloud, Immich)
#   · AFFiNE data     /mnt/ssd/affine/
#   · Nextcloud data  /mnt/ssd/nextcloud/
#   · Stack configs   ~/stacks/
#   · Immich originals /mnt/ssd/immich/
#
# Backup layout on external drive:
#   /mnt/backup/
#     backups/
#       2026-09-15_143022/
#         db-dumps/    ← SQL dumps
#         affine/      ← rsync of /mnt/ssd/affine
#         nextcloud/   ← rsync of /mnt/ssd/nextcloud
#         stacks/      ← rsync of ~/stacks (configs only, no .env files)
#         manifest.txt ← what was backed up and sizes
#     latest           ← symlink to most recent backup
#     backup.log       ← running log of all backup runs

set -euo pipefail

# ── Config (override via environment) ────────────────────────────────────────
BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
SSD_AFFINE="${SSD_AFFINE:-/mnt/ssd/affine}"
SSD_NEXTCLOUD="${SSD_NEXTCLOUD:-/mnt/ssd/nextcloud}"
SSD_IMMICH="${SSD_IMMICH:-/mnt/ssd/immich}"
STACKS_DIR="${STACKS_DIR:-${HOME}/stacks}"

PROD_POSTGRES_CONTAINER="${PROD_POSTGRES_CONTAINER:-prod-postgres}"
IMMICH_POSTGRES_CONTAINER="${IMMICH_POSTGRES_CONTAINER:-immich-postgres}"
POSTGRES_USER="${POSTGRES_USER:-appuser}"
IMMICH_DB_USER="${IMMICH_DB_USER:-immich}"

# ── Parse args ────────────────────────────────────────────────────────────────
DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --dry-run)    DRY_RUN=true ;;
    --only-db)    ONLY_DB=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

ONLY_DB="${ONLY_DB:-false}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
info()    { echo -e "  ${BLUE}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
section() { echo; echo -e "${BOLD}$*${NC}"; echo "──────────────────────────────────────"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="${BACKUP_MOUNT}/backups/${TIMESTAMP}"
LOG_FILE="${BACKUP_MOUNT}/backup.log"
START_TIME=$(date +%s)

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  if [[ "${DRY_RUN}" == false ]]; then
    echo "$msg" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

rsync_cmd() {
  local src="$1" dst="$2" label="$3"
  info "Syncing ${label}..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "    [DRY RUN] rsync -aH --delete --stats ${src} ${dst}"
  else
    rsync -aH --delete --stats --human-readable \
      --exclude='.env' \
      "${src}" "${dst}" \
      | grep -E '^(Number|Total|sent|receiving|Literal|Matched)' | sed 's/^/    /' || true
    ok "${label} synced"
  fi
}

bytes_to_human() {
  local bytes=$1
  if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
  elif (( bytes >= 1048576 ));    then printf "%.1f MB" "$(echo "scale=1; $bytes/1048576" | bc)"
  else printf "%d KB" "$(( bytes / 1024 ))"
  fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
section "Pre-flight checks"

# Check backup drive
if ! "${BASH_SOURCE%/*}/check-mount.sh" 2>&1; then
  fail "Backup drive not ready. Run ./check-mount.sh for details."
fi

# Check Docker is running
if ! docker info &>/dev/null; then
  fail "Docker is not running. Start Docker first."
fi

# Check rsync
if ! command -v rsync &>/dev/null; then
  fail "rsync not found. Install it: sudo apt-get install -y rsync"
fi

if [[ "${DRY_RUN}" == true ]]; then
  warn "DRY RUN — no files will be written"
fi

echo
echo -e "  Backup ID:   ${BOLD}${TIMESTAMP}${NC}"
echo -e "  Destination: ${BACKUP_DIR}"
echo -e "  DB only:     ${ONLY_DB}"

# ── Create backup directory ───────────────────────────────────────────────────
if [[ "${DRY_RUN}" == false ]]; then
  mkdir -p \
    "${BACKUP_DIR}/db-dumps" \
    "${BACKUP_DIR}/affine" \
    "${BACKUP_DIR}/nextcloud" \
    "${BACKUP_DIR}/immich" \
    "${BACKUP_DIR}/stacks"
fi

# ── 1. Database dumps ─────────────────────────────────────────────────────────
section "1 / 5  Database dumps"

dump_db() {
  local container="$1" db_user="$2" db_name="$3" label="$4"
  local out="${BACKUP_DIR}/db-dumps/${db_name}_${TIMESTAMP}.sql"

  info "Dumping ${label} (${db_name})..."

  if ! docker inspect "${container}" &>/dev/null; then
    warn "${container} container not found — skipping ${label} dump"
    return
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    echo "    [DRY RUN] docker exec ${container} pg_dump -U ${db_user} ${db_name} > ${out}"
  else
    docker exec "${container}" pg_dump -U "${db_user}" "${db_name}" > "${out}"
    local size
    size=$(du -h "${out}" | cut -f1)
    ok "${label} dumped (${size})"
  fi
}

dump_db "${PROD_POSTGRES_CONTAINER}"   "${POSTGRES_USER}"  "affine"    "AFFiNE"
dump_db "${PROD_POSTGRES_CONTAINER}"   "${POSTGRES_USER}"  "nextcloud" "Nextcloud"
dump_db "${IMMICH_POSTGRES_CONTAINER}" "${IMMICH_DB_USER}" "immich"    "Immich"

if [[ "${ONLY_DB}" == true ]]; then
  ok "DB-only mode — skipping file sync"
  section "Done"
  echo -e "  ${GREEN}${BOLD}Database dumps complete.${NC}"
  echo -e "  Location: ${BACKUP_DIR}/db-dumps/"
  exit 0
fi

# ── 2. AFFiNE data ───────────────────────────────────────────────────────────
section "2 / 5  AFFiNE data"
rsync_cmd "${SSD_AFFINE}/" "${BACKUP_DIR}/affine/" "AFFiNE"

# ── 3. Nextcloud data ─────────────────────────────────────────────────────────
section "3 / 5  Nextcloud data"
rsync_cmd "${SSD_NEXTCLOUD}/" "${BACKUP_DIR}/nextcloud/" "Nextcloud"

# ── 4. Immich originals ───────────────────────────────────────────────────────
section "4 / 5  Immich originals"
rsync_cmd "${SSD_IMMICH}/upload/" "${BACKUP_DIR}/immich/" "Immich originals"

# ── 5. Stack configs ──────────────────────────────────────────────────────────
section "5 / 5  Stack configs"
rsync_cmd "${STACKS_DIR}/" "${BACKUP_DIR}/stacks/" "Stacks"
warn ".env files excluded — credentials stay local only"

# ── Write manifest ────────────────────────────────────────────────────────────
if [[ "${DRY_RUN}" == false ]]; then
  MANIFEST="${BACKUP_DIR}/manifest.txt"
  {
    echo "oryx backup — ${TIMESTAMP}"
    echo "Host:        $(hostname)"
    echo "Date:        $(date)"
    echo
    echo "Contents:"
    du -sh "${BACKUP_DIR}"/* 2>/dev/null | sed 's/^/  /'
    echo
    echo "Total size:"
    du -sh "${BACKUP_DIR}" | sed 's/^/  /'
  } > "${MANIFEST}"

  # Update 'latest' symlink
  ln -sfn "backups/${TIMESTAMP}" "${BACKUP_MOUNT}/latest"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_FMT=$(printf '%dm %ds' "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))")

section "Summary"
if [[ "${DRY_RUN}" == false ]]; then
  BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo "unknown")
  echo -e "  Backup ID:  ${BOLD}${TIMESTAMP}${NC}"
  echo -e "  Location:   ${BACKUP_DIR}"
  echo -e "  Size:       ${BACKUP_SIZE}"
  echo -e "  Duration:   ${ELAPSED_FMT}"
  echo
  echo -e "  ${GREEN}${BOLD}Backup complete.${NC}"
  log "Backup completed: ${TIMESTAMP} size=${BACKUP_SIZE} duration=${ELAPSED_FMT}"
else
  echo -e "  ${YELLOW}${BOLD}Dry run complete — nothing written.${NC}"
  echo -e "  Run without --dry-run to perform the actual backup."
fi
echo
