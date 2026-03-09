#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 04: Base Arch installation into /mnt
#
# Requirements:
#   - /mnt must be mounted (Btrfs subvol @ mounted as /mnt, ESP mounted as /mnt/boot)
#
# Actions:
#   - Ensure network is up
#   - Update archlinux-keyring (live ISO)
#   - Install reflector (live ISO) and select mirrors (VN/SG/JP/KR)
#   - pacstrap base system packages into /mnt
#   - Optimize pacman.conf INSIDE the installed system (/mnt/etc/pacman.conf)
#   - genfstab -U to /mnt/etc/fstab and print it
# ==============================================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    warn "Step 04 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root."

require_cmd mountpoint
require_cmd pacman
require_cmd pacstrap
require_cmd genfstab
require_cmd sync

if ! mountpoint -q /mnt; then
  die "/mnt is not mounted. Run steps 01-03 first."
fi

# Minimal network check: route + ping/curl
info "Checking network connectivity..."
if command -v ip >/dev/null 2>&1; then
  ip route >/dev/null 2>&1 || true
fi

NET_OK=0
if command -v ping >/dev/null 2>&1; then
  if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    NET_OK=1
  fi
fi
if [[ $NET_OK -eq 0 ]] && command -v curl >/dev/null 2>&1; then
  if curl -fsSLI --max-time 5 https://archlinux.org >/dev/null 2>&1; then
    NET_OK=1
  fi
fi
[[ $NET_OK -eq 1 ]] || die "Network appears offline. Configure Wi-Fi (iwctl) or Ethernet, then re-run."

info "Updating pacman keyring (live ISO)..."
pacman -Sy --noconfirm archlinux-keyring

info "Installing reflector (live ISO)..."
pacman -S --noconfirm --needed reflector

info "Selecting fastest mirrors (VN/SG/JP/KR)..."
# If reflector fails (rare), keep current mirrorlist and continue.
if ! reflector \
  --country Vietnam,Singapore,Japan,South\ Korea \
  --age 12 \
  --protocol https \
  --sort rate \
  --latest 20 \
  --save /etc/pacman.d/mirrorlist; then
  warn "Reflector failed; continuing with current /etc/pacman.d/mirrorlist."
fi

info "Installing base system into /mnt..."
pacstrap /mnt \
  base \
  base-devel \
  linux-firmware \
  btrfs-progs \
  networkmanager \
  sudo \
  intel-ucode

info "Optimizing pacman.conf in target system (/mnt/etc/pacman.conf)..."
TARGET_PACCONF="/mnt/etc/pacman.conf"
[[ -f "$TARGET_PACCONF" ]] || die "Missing $TARGET_PACCONF after pacstrap."

sed -i 's/^#Color/Color/' "$TARGET_PACCONF"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$TARGET_PACCONF"
grep -q '^ILoveCandy' "$TARGET_PACCONF" || sed -i '/^Color/a ILoveCandy' "$TARGET_PACCONF"

info "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab
sync

echo
info "Generated /mnt/etc/fstab:"
echo "--------------------------------"
cat /mnt/etc/fstab
echo "--------------------------------"
echo
info "Base system installation complete."
