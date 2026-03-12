#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 04: Base Arch installation into /mnt
# - uses pacstrap + genfstab
# - uses default Arch mirrorlist from live ISO (no reflector)
# - modifies /mnt/etc/pacman.conf (Color, ParallelDownloads, ILoveCandy)
# ==============================================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  ec=$?
  if (( ec != 0 )); then
    warn "Step 04 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."

require_cmd mountpoint
require_cmd pacman
require_cmd pacstrap
require_cmd genfstab
require_cmd sync

mountpoint -q /mnt || die "/mnt is not mounted (run steps 01-03)."

info "Checking network connectivity..."
NET_OK=0
if command -v ping >/dev/null 2>&1 && ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
  NET_OK=1
fi
if [[ $NET_OK -eq 0 ]] && command -v curl >/dev/null 2>&1; then
  curl -fsSLI --max-time 5 https://archlinux.org >/dev/null 2>&1 && NET_OK=1 || true
fi
[[ $NET_OK -eq 1 ]] || die "Network appears offline. Configure Wi-Fi (iwctl) or Ethernet, then re-run."

info "Updating pacman keyring (live ISO)..."
pacman -Sy --noconfirm archlinux-keyring || die "Failed to update keyring"

info "Refreshing package databases..."
pacman -Syy

info "Installing base system into /mnt..."
pacstrap -K /mnt \
  base \
  base-devel \
  linux-firmware \
  btrfs-progs \
  networkmanager \
  sudo \
  intel-ucode \
  mkinitcpio \
  iptables-nft

info "Optimizing pacman.conf in target system (/mnt/etc/pacman.conf)..."
TARGET_PACCONF="/mnt/etc/pacman.conf"
[[ -f "$TARGET_PACCONF" ]] || die "Missing $TARGET_PACCONF after pacstrap."

sed -i 's/^#Color/Color/' "$TARGET_PACCONF"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$TARGET_PACCONF"
grep -q '^ILoveCandy' "$TARGET_PACCONF" || sed -i '/^Color/a ILoveCandy' "$TARGET_PACCONF"
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$TARGET_PACCONF"

info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Remove duplicate entries if script rerun
awk '!seen[$0]++' /mnt/etc/fstab > /mnt/etc/fstab.new
mv /mnt/etc/fstab.new /mnt/etc/fstab

sync

echo
info "Generated /mnt/etc/fstab:"
echo "--------------------------------"
cat /mnt/etc/fstab
echo "--------------------------------"
info "Base system installation complete."
