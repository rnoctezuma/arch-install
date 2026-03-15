#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 05: System configuration (RUN INSIDE arch-chroot /mnt)
# Target: vanilla Arch base configuration
#
# Key goals:
# - Locale/timezone/users/sudo baseline
# - Enable multilib
# - Install baseline packages
# - mkinitcpio: systemd initramfs + sd-encrypt
# ==============================================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  if (( ec != 0 )); then
    warn "Step 05 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root (inside chroot)."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
grep -q '^ID=arch$' /etc/os-release || die "Not inside target Arch system (arch-chroot missing)."

require_cmd pacman
require_cmd sed
require_cmd locale-gen
require_cmd mkinitcpio
require_cmd systemctl
require_cmd awk
require_cmd grep
require_cmd find
require_cmd hwclock
require_cmd useradd
require_cmd passwd
require_cmd install

set_mkinitcpio_var() {
  local key="$1"
  local value="$2"
  local file="/etc/mkinitcpio.conf"

  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -Ei "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# ---- Timezone / locale --------------------------------------------------------
TIMEZONE="Asia/Ho_Chi_Minh"
if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
  die "Timezone file not found: ${TIMEZONE}"
fi
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

info "Configuring locale: en_US.UTF-8"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf "LANG=en_US.UTF-8\n" > /etc/locale.conf
printf "KEYMAP=us\n" > /etc/vconsole.conf

# ---- Hostname / hosts ---------------------------------------------------------
info "Setting hostname"
read -rp "Enter hostname (default: arch): " hostname
hostname="${hostname:-arch}"
if ! [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  die "Invalid hostname: $hostname"
fi
printf "%s\n" "$hostname" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${hostname}.localdomain ${hostname}
EOF

# ---- Accounts -----------------------------------------------------------------
info "Set root password"
passwd

info "Creating user"
read -rp "Enter username (default: rnoct): " username
username="${username:-rnoct}"

if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  die "Invalid username: $username"
fi

if id -u "$username" >/dev/null 2>&1; then
  warn "User '$username' already exists; skipping useradd."
else
  useradd -m -G wheel -s /bin/bash "$username"
fi

passwd "$username"

info "Enabling sudo for wheel group (sudoers.d)"
install -d -m 0755 /etc/sudoers.d
printf "%%wheel ALL=(ALL:ALL) ALL\n" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# ---- pacman: multilib ---------------------------------------------------------
info "Enabling multilib (needed for many 32-bit libraries)"
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  awk '
    BEGIN{inml=0}
    /^\s*#\s*\[multilib\]\s*$/ {print "[multilib]"; inml=1; next}
    inml && /^\s*#\s*Include = \/etc\/pacman.d\/mirrorlist\s*$/ {sub(/^\s*#\s*/,""); print; inml=0; next}
    {print}
  ' /etc/pacman.conf > /etc/pacman.conf.new
  mv /etc/pacman.conf.new /etc/pacman.conf
fi

# ---- Baseline packages --------------------------------------------------------
info "Refreshing package databases"
pacman -Syy --noconfirm

info "Installing essential packages"
pacman -S --noconfirm --needed \
  nano \
  git \
  htop \
  fastfetch \
  mesa \
  vulkan-icd-loader \
  dosfstools \
  pacman-contrib \
  efibootmgr \
  dkms \
  linux-zen-headers \
  linux-lts-headers \
  nvidia-open-dkms \
  nvidia-utils \
  lib32-nvidia-utils \
  nvidia-settings

# ---- mkinitcpio ---------------------------------------------------------------
info "Configuring mkinitcpio for systemd initramfs + sd-encrypt"
set_mkinitcpio_var MODULES '(btrfs nvme nvidia nvidia_modeset nvidia_uvm nvidia_drm)'
set_mkinitcpio_var HOOKS '(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)'

info "Enabling mkinitcpio fallback presets for installed kernels"
while IFS= read -r preset; do
  [[ -f "$preset" ]] || continue
  sed -i "s/^PRESETS=('default')/PRESETS=('default' 'fallback')/" "$preset"
done < <(find /etc/mkinitcpio.d -maxdepth 1 -type f \( -name 'linux-*.preset' -o -name 'linux*.preset' \))

info "Building initramfs for all presets"
mkinitcpio -P

info "Enabling NetworkManager"
systemctl enable NetworkManager

info "System configuration complete."