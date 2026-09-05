#!/usr/bin/env bash
# setup.sh — Optiplex home server setup
#
# Run this after installing Ubuntu 26.04 LTS and SSH-ing in from your laptop.
# Copy to server first:
#   scp setup.sh aritra@<server-ip>:~/setup.sh
#   ssh aritra@<server-ip>
#   bash setup.sh
#
# Idempotent — safe to re-run. Already-completed steps are skipped.

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
info()    { echo -e "  ${BLUE}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
section() { echo; echo -e "${BOLD}$*${NC}"; echo "────────────────────────────────────────────"; }
skip()    { echo -e "  ${DIM}–  $* (already done)${NC}"; }

confirm() {
  local prompt="$1"
  read -r -p "  $prompt [y/N] " ans
  [[ "${ans,,}" == "y" ]]
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
section "Pre-flight checks"

[[ $EUID -ne 0 ]] || fail "Do not run as root. Run as your regular user with sudo access."
command -v sudo &>/dev/null || fail "sudo not found."

# Ubuntu 26.04 check
if grep -q "26.04" /etc/os-release 2>/dev/null; then
  ok "Ubuntu 26.04 LTS detected"
else
  warn "Expected Ubuntu 26.04 — proceeding anyway"
fi

ok "Running as $(whoami)"
REAL_HOME=$(eval echo "~$(whoami)")

# ── Phase 0: Required packages ───────────────────────────────────────────────
section "Phase 0 — Required packages"

declare -A _DEPS=(
  [ufw]=ufw
  [parted]=parted
  [mkfs.ext4]=e2fsprogs
  [curl]=curl
)
_MISSING=()

for _cmd in "${!_DEPS[@]}"; do
  command -v "${_cmd}" &>/dev/null || _MISSING+=("${_DEPS[$_cmd]}")
done

if [[ ${#_MISSING[@]} -gt 0 ]]; then
  info "Installing missing packages: ${_MISSING[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${_MISSING[@]}"
  ok "Installed: ${_MISSING[*]}"
else
  skip "All required packages present"
fi

unset _DEPS _MISSING _cmd

# ── Phase 1: SSH hardening ────────────────────────────────────────────────────
section "Phase 1 — SSH hardening"

if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
  skip "Password auth already disabled"
else
  if ! [[ -f ~/.ssh/authorized_keys ]]; then
    warn "No SSH key found in ~/.ssh/authorized_keys"
    warn "Add your public key BEFORE disabling password auth, or you'll be locked out."
    confirm "Continue anyway?" || { echo "  Skipping SSH hardening."; }
  fi
  info "Disabling SSH password authentication..."
  sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sudo systemctl restart ssh
  ok "Password auth disabled — key-only login from now on"
fi

# ── Phase 2: Firewall ─────────────────────────────────────────────────────────
section "Phase 2 — Firewall (UFW)"

if sudo ufw status | grep -q "Status: active"; then
  skip "UFW already active"
else
  info "Configuring UFW..."
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh
  sudo ufw --force enable
  ok "UFW enabled — SSH allowed, everything else blocked"
fi

# ── Phase 3: Auto security updates ───────────────────────────────────────────
section "Phase 3 — Automatic security updates"

if dpkg -l unattended-upgrades &>/dev/null; then
  skip "unattended-upgrades already installed"
else
  info "Installing unattended-upgrades..."
  sudo apt-get update -qq
  sudo apt-get install -y unattended-upgrades
  echo 'Unattended-Upgrade::Automatic-Reboot "false";' | \
    sudo tee /etc/apt/apt.conf.d/99no-reboot > /dev/null
  ok "Automatic security updates enabled"
fi

# ── Phase 4: Static IP ────────────────────────────────────────────────────────
section "Phase 4 — Static LAN IP"

NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
if grep -q "dhcp4: no" "${NETPLAN_FILE}" 2>/dev/null; then
  CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1)
  skip "Static IP already configured (${CURRENT_IP})"
else
  echo
  echo "  Current network interfaces:"
  ip -br link show | grep -v lo | sed 's/^/    /'
  echo
  read -r -p "  Enter interface name (e.g. enp3s0): " IFACE
  read -r -p "  Enter static IP (e.g. 192.168.1.100): " STATIC_IP
  read -r -p "  Enter gateway (e.g. 192.168.1.1): " GATEWAY

  sudo tee /etc/netplan/00-installer-config.yaml > /dev/null << EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses:
        - ${STATIC_IP}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [127.0.0.1, 1.1.1.1]   # 127.0.0.1 = Pi-hole (once running); 1.1.1.1 fallback
EOF

  sudo netplan apply
  ok "Static IP set to ${STATIC_IP} via ${IFACE}"
  warn "Also reserve ${STATIC_IP} in your router's DHCP settings"
fi

# ── Phase 5: Format and mount SATA SSD ───────────────────────────────────────
section "Phase 5 — SATA SSD (app data drive)"

if mountpoint -q /mnt/ssd 2>/dev/null; then
  skip "/mnt/ssd already mounted ($(df -h /mnt/ssd | awk 'NR==2{print $2}') drive)"
else
  echo
  echo "  Attached block devices:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | sed 's/^/    /'
  echo
  warn "You are about to FORMAT a drive. All data on it will be ERASED."
  echo
  read -r -p "  Enter device to format as app data drive (e.g. sda): " SSD_DEV
  SSD_DEV="/dev/${SSD_DEV%%[0-9]*}"   # strip partition suffix if given

  echo
  warn "This will WIPE ${SSD_DEV} — are you sure?"
  confirm "Format ${SSD_DEV}?" || fail "Aborted."

  info "Partitioning ${SSD_DEV}..."
  sudo parted "${SSD_DEV}" --script mklabel gpt
  sudo parted "${SSD_DEV}" --script mkpart primary ext4 0% 100%
  sudo mkfs.ext4 -L ssd "${SSD_DEV}1"
  ok "${SSD_DEV}1 formatted as ext4"

  info "Mounting at /mnt/ssd..."
  sudo mkdir -p /mnt/ssd
  SSD_UUID=$(sudo blkid -s UUID -o value "${SSD_DEV}1")
  grep -q "${SSD_UUID}" /etc/fstab 2>/dev/null || \
    echo "UUID=${SSD_UUID}  /mnt/ssd  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
  sudo mount -a
  ok "/mnt/ssd mounted (UUID: ${SSD_UUID})"
fi

# ── Phase 6: Directory structure ─────────────────────────────────────────────
section "Phase 6 — Directory structure"

info "Creating /opt/ service directories (NVMe)..."
sudo mkdir -p \
  /opt/pihole/etc \
  /opt/pihole/dnsmasq \
  /opt/cloudflared \
  /opt/glance \
  /opt/portainer \
  /opt/monitoring/prometheus \
  /opt/monitoring/grafana \
  /opt/monitoring/uptime-kuma \
  /opt/docker \
  /opt/dev/postgres \
  /opt/dev/elasticsearch

# Glance needs a config file — Docker creates a directory if it doesn't exist
touch /opt/glance/glance.yml 2>/dev/null || sudo touch /opt/glance/glance.yml

info "Creating /mnt/ssd/ app data directories..."
sudo mkdir -p \
  /mnt/ssd/affine/data \
  /mnt/ssd/affine/postgres \
  /mnt/ssd/nextcloud/data \
  /mnt/ssd/nextcloud/config \
  /mnt/ssd/nextcloud/apps \
  /mnt/ssd/immich/upload \
  /mnt/ssd/immich/postgres \
  /mnt/ssd/immich/model-cache

sudo chown -R "$(whoami):$(whoami)" /opt /mnt/ssd
ok "All directories created"

# ── Phase 7: Docker ───────────────────────────────────────────────────────────
section "Phase 7 — Docker"

if command -v docker &>/dev/null; then
  skip "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$(whoami)"
  ok "Docker installed"
  warn "You'll need to log out and back in for the docker group to take effect"
  warn "Or run: newgrp docker"
fi

if [[ -f /etc/docker/daemon.json ]]; then
  skip "Docker daemon.json already configured"
else
  info "Configuring Docker data-root → /opt/docker..."
  sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "data-root": "/opt/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
  sudo systemctl restart docker
  ok "Docker data-root set to /opt/docker"
fi

if docker network ls 2>/dev/null | grep -q "server-net"; then
  skip "server-net network already exists"
else
  # Need docker group in this shell
  if groups | grep -q docker; then
    docker network create server-net
    ok "server-net Docker network created"
  else
    info "Run this after logging out and back in:"
    echo "    docker network create server-net"
  fi
fi

# ── Phase 8: Tailscale ────────────────────────────────────────────────────────
section "Phase 8 — Tailscale"

if command -v tailscale &>/dev/null; then
  skip "Tailscale already installed"
  tailscale status 2>/dev/null | head -3 | sed 's/^/    /' || true
else
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sudo sh
  ok "Tailscale installed"
fi

if tailscale status &>/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4 2>/dev/null || echo "not yet connected")
  skip "Tailscale already authenticated (IP: ${TS_IP})"
else
  echo
  info "Authenticate Tailscale — a URL will appear below."
  info "Open it in a browser, authorize the device, then return here."
  echo
  sudo tailscale up --ssh
  ok "Tailscale connected"
  echo
  TS_IP=$(tailscale ip -4 2>/dev/null || echo "see: tailscale ip -4")
  echo -e "  ${BOLD}Tailscale IP: ${TS_IP}${NC}"
  warn "Save this IP — it's your permanent remote access address"
fi

sudo systemctl enable --now tailscaled 2>/dev/null || true

# ── Phase 9: Stacks directory ─────────────────────────────────────────────────
section "Phase 9 — Stacks directory"

STACKS="${REAL_HOME}/stacks"

if [[ -d "${STACKS}/infra" ]]; then
  skip "~/stacks already exists"
else
  info "Creating ~/stacks directory structure..."
  mkdir -p "${STACKS}"/{infra,media,productivity,monitoring,dev}
  ok "~/stacks/{infra,media,productivity,monitoring,dev} created"
fi

# If the oryx repo is available, copy compose templates
ORYX_DIR="${REAL_HOME}/oryx"
if [[ -d "${ORYX_DIR}/stacks" ]]; then
  info "Copying compose files from ~/oryx/stacks/..."
  cp -rn "${ORYX_DIR}/stacks/." "${STACKS}/" 2>/dev/null || true
  ok "Compose files copied to ~/stacks/"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
section "Setup complete"

echo
echo -e "  ${GREEN}${BOLD}All phases done.${NC}"
echo
echo "  Next steps:"
echo
echo "  1. Log out and back in (docker group takes effect)"
echo "  2. Run: docker network create server-net"
echo "  3. Fill in ~/stacks/infra/.env then:"
echo "        cd ~/stacks/infra && docker compose up -d pihole glance watchtower portainer"
echo "  4. Set your router's primary DNS to your static LAN IP"
echo "  5. Set up Cloudflare Tunnel (see docs/setup.md Phase 7)"
echo
TS_IP=$(tailscale ip -4 2>/dev/null || echo "<run: tailscale ip -4>")
echo -e "  Tailscale IP: ${BOLD}${TS_IP}${NC}"
echo -e "  SSH from anywhere: ${BOLD}ssh $(whoami)@${TS_IP}${NC}"
echo
