#!/usr/bin/env bash
# update.sh — manually update Docker containers
#
# Watchtower already updates everything nightly at 3am.
# Use this when you want to update immediately, or a specific stack.
#
# Usage:
#   ./update.sh                  update all stacks
#   ./update.sh infra            update a single stack
#   ./update.sh infra media      update multiple stacks
#   ./update.sh --list           show running container versions

set -euo pipefail

STACKS_DIR="${HOME}/stacks"
ALL_STACKS=(infra productivity media monitoring)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
info()    { echo -e "  ${BLUE}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
section() { echo; echo -e "${BOLD}$*${NC}"; echo "────────────────────────────────────────"; }

# ── Dependency check ─────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo -e "  ${RED}✗${NC}  docker not found. Install it first:" >&2
  echo "      curl -fsSL https://get.docker.com | sudo sh" >&2
  exit 1
fi

# ── List mode ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
  section "Running containers"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | \
    awk 'NR==1{print "  "$0} NR>1{print "  "$0}'
  exit 0
fi

# ── Update function ───────────────────────────────────────────────────────────
update_stack() {
  local stack="$1"
  local stack_dir="${STACKS_DIR}/${stack}"

  if [[ ! -d "${stack_dir}" ]]; then
    warn "Stack '${stack}' not found at ${stack_dir} — skipping"
    return
  fi

  if [[ ! -f "${stack_dir}/docker-compose.yml" ]]; then
    warn "No docker-compose.yml in ${stack_dir} — skipping"
    return
  fi

  section "Updating ${stack}"

  cd "${stack_dir}"

  info "Pulling latest images..."
  docker compose pull

  info "Recreating updated containers..."
  docker compose up -d --remove-orphans

  # Show what's running
  echo
  docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}" | \
    awk 'NR==1{print "  "$0} NR>1{print "  "$0}'

  ok "${stack} updated"
}

# ── Main ──────────────────────────────────────────────────────────────────────
START=$(date +%s)

if [[ $# -eq 0 ]]; then
  echo -e "${BOLD}Updating all stacks${NC}"
  warn "Watchtower already does this at 3am — run this for an immediate update"
  echo
  for stack in "${ALL_STACKS[@]}"; do
    update_stack "$stack"
  done
else
  for stack in "$@"; do
    update_stack "$stack"
  done
fi

END=$(date +%s)
section "Done"
echo -e "  ${GREEN}${BOLD}All updates complete${NC} ($(( END - START ))s)"
echo
echo "  To check container status:  docker ps"
echo "  To check logs:              docker logs <container-name>"
echo
