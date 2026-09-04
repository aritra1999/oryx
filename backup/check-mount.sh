#!/usr/bin/env bash
# check-mount.sh — verify the backup drive is mounted, writable, and has enough space.
#
# Usage:
#   ./check-mount.sh                 check with defaults
#   BACKUP_MOUNT=/mnt/backup ./check-mount.sh
#   MIN_FREE_GB=100 ./check-mount.sh
#
# Exit codes:
#   0 — drive is ready
#   1 — drive is not ready (error printed to stderr)

set -euo pipefail

BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/backup}"
MIN_FREE_GB="${MIN_FREE_GB:-50}"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*" >&2; echo >&2; exit 1; }

echo
echo -e "${BOLD}Checking backup drive at ${BACKUP_MOUNT}${NC}"
echo "──────────────────────────────────────"

# ── 1. Is it a mount point? ───────────────────────────────────────────────────
if ! mountpoint -q "${BACKUP_MOUNT}" 2>/dev/null; then
  fail "${BACKUP_MOUNT} is not mounted.

  To mount the backup drive:
    lsblk -o NAME,SIZE,LABEL,FSTYPE,MOUNTPOINT   # find your drive
    sudo mkdir -p ${BACKUP_MOUNT}
    sudo mount /dev/sdX ${BACKUP_MOUNT}           # replace sdX with your drive"
fi
ok "Drive mounted at ${BACKUP_MOUNT}"

# ── 2. Is the filesystem healthy? ────────────────────────────────────────────
FS_TYPE=$(findmnt -n -o FSTYPE "${BACKUP_MOUNT}" 2>/dev/null || echo "unknown")
ok "Filesystem: ${FS_TYPE}"

# ── 3. Is it writable? ───────────────────────────────────────────────────────
TEST_FILE="${BACKUP_MOUNT}/.write_test_$$"
if ! touch "${TEST_FILE}" 2>/dev/null; then
  fail "${BACKUP_MOUNT} is not writable. Drive may be mounted read-only."
fi
rm -f "${TEST_FILE}"
ok "Drive is writable"

# ── 4. Free space ────────────────────────────────────────────────────────────
FREE_BYTES=$(df --output=avail -B1 "${BACKUP_MOUNT}" | tail -1)
TOTAL_BYTES=$(df --output=size  -B1 "${BACKUP_MOUNT}" | tail -1)
USED_PCT=$(df --output=pcent       "${BACKUP_MOUNT}" | tail -1 | tr -d ' %')

FREE_GB=$(( FREE_BYTES  / 1024 / 1024 / 1024 ))
TOTAL_GB=$(( TOTAL_BYTES / 1024 / 1024 / 1024 ))

if (( FREE_GB < MIN_FREE_GB )); then
  fail "Only ${FREE_GB} GB free on ${BACKUP_MOUNT} — need at least ${MIN_FREE_GB} GB.
  Delete old backups or use a larger drive."
fi

if (( USED_PCT >= 85 )); then
  warn "${FREE_GB} GB free of ${TOTAL_GB} GB (${USED_PCT}% used) — getting full"
else
  ok "${FREE_GB} GB free of ${TOTAL_GB} GB (${USED_PCT}% used)"
fi

# ── 5. Existing backups ───────────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_MOUNT}/backups"
if [[ -d "${BACKUP_DIR}" ]]; then
  COUNT=$(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d | wc -l)
  LATEST=$(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d | sort | tail -1 | xargs basename 2>/dev/null || echo "none")
  ok "${COUNT} existing backup(s) — latest: ${LATEST}"
else
  warn "No backups found yet — first run will create ${BACKUP_DIR}"
fi

echo "──────────────────────────────────────"
echo -e "  ${GREEN}${BOLD}Backup drive is ready.${NC}"
echo
