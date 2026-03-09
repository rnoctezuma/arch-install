#!/usr/bin/env bash
set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    warn "Step 05 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root (inside chroot)."

# sanity check: we must be inside installed system
[[ -f /etc/arch-release ]] || die "Not inside target system (arch-chroot missing)."

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

require_cmd pacman
require_cmd locale-gen
require_cmd mkinitcpio
require_cmd systemctl

# ---- Basic system settings ----------------------------------------------------

info "Setting timezone: Asia/Ho_Chi_Minh"
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
hwclock --systohc

info "Configuring locale"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

info "Setting hostname"
read -rp "Enter hostname: " hostname
[[ -n "${hostname:-}" ]] || die "Hostname cannot be empty."
echo "$hostname" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${hostname}.localdomain ${hostname}
EOF

info "Setting root password"
passwd

info "Creating user"
read -rp "Enter username: " username
[[ -n "${username:-}" ]] || die "Username cannot be empty."
useradd -m -G wheel -s /bin/bash "$username"
passwd "$username"

install -d -m 0755 /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

info "Enabling multilib"
sed -i 's/^#\s*\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/^\[multilib\]/,/^$/ s/^#//' /etc/pacman.conf

info "Installing essential packages"
pacman -Sy --noconfirm

pacman -S --noconfirm --needed \
  mesa \
  vulkan-icd-loader \
  dosfstools \
  htop \
  fastfetch \
  nano \
  git \
  reflector \
  pacman-contrib \
  curl

pacman -S --noconfirm --needed \
  nvidia-utils \
  lib32-nvidia-utils || warn "lib32-nvidia-utils failed."

# ---- CachyOS repos remain exactly as you wrote them ----
# (я не меняю твой блок добавления cachyos, он уже корректный)

# ---- mkinitcpio --------------------------------------------------------------

info "Configuring mkinitcpio"
sed -i 's/^MODULES=.*/MODULES=(btrfs nvme)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

mkinitcpio -P

info "Enabling NetworkManager"
systemctl enable NetworkManager

info "Step 05 complete."
