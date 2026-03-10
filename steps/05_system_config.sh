#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 05: System configuration (RUN INSIDE arch-chroot /mnt)
# Target: Intel + NVIDIA laptop (Lenovo Legion i7 Pro Gen10)
#
# Key goals:
# - Locale/timezone/users/sudo baseline
# - Enable multilib (gaming)
# - Add CachyOS repos FORCE x86-64-v3 (Intel hybrid caution)
# - Install linux-cachyos + linux-cachyos-nvidia-open + headers
# - Install nvidia-utils + lib32-nvidia-utils from CachyOS repos (match driver)
# - mkinitcpio: systemd initramfs + sd-encrypt
# ==============================================================================

TMPDIR=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  ec=$?
  if (( ec != 0 )); then
    warn "Step 05 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root (inside chroot)."
[[ -f /etc/arch-release ]] || die "Not inside target system (arch-chroot missing)."

require_cmd pacman
require_cmd sed
require_cmd locale-gen
require_cmd mkinitcpio
require_cmd systemctl
require_cmd curl
require_cmd awk
require_cmd grep
require_cmd sort
require_cmd tail
require_cmd pacman-key

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
[[ -n "${username:-rnoct}" ]] || die "Username cannot be empty."
if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  die "Invalid username: $username"
fi

useradd -m -G wheel -s /bin/bash "$username"
passwd "$username"

info "Enabling sudo for wheel group (sudoers.d)"
install -d -m 0755 /etc/sudoers.d
printf "%%wheel ALL=(ALL:ALL) ALL\n" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# ---- pacman: multilib ---------------------------------------------------------
info "Enabling multilib (needed for many gaming 32-bit libs)"
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  awk '
    BEGIN{done=0; inml=0}
    /^\s*#\s*\[multilib\]\s*$/ {print "[multilib]"; inml=1; done=1; next}
    inml && /^\s*#\s*Include = \/etc\/pacman.d\/mirrorlist\s*$/ {sub(/^\s*#\s*/,""); print; inml=0; next}
    {print}
  ' /etc/pacman.conf > /etc/pacman.conf.new
  mv /etc/pacman.conf.new /etc/pacman.conf
fi

# ---- Baseline packages --------------------------------------------------------
info "Installing essential packages (baseline)"
pacman -Syy --noconfirm

pacman -S --noconfirm --needed \
  nano git htop fastfetch curl \
  mesa vulkan-icd-loader \
  dosfstools \
  reflector pacman-contrib \
  efibootmgr

# ---- CachyOS repos: FORCE x86-64-v3 ------------------------------------------
info "Adding CachyOS repos (FORCE x86-64-v3)"

# Ensure pacman keyring exists
if [[ ! -d /etc/pacman.d/gnupg ]]; then
  info "Initializing pacman keyring..."
  pacman-key --init
  pacman-key --populate archlinux
fi

# Download latest keyring + mirrorlist packages by parsing official mirror listing.
CACHY_BASE_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
TMPDIR="$(mktemp -d)"

LISTING="$(curl -fsSL "$CACHY_BASE_URL/")" || die "Failed to fetch $CACHY_BASE_URL/"

pick_latest() {
  local pattern="$1"
  echo "$LISTING" | grep -oE "$pattern" | sort -V | tail -n 1
}

KEYRING_PKG="$(pick_latest 'cachyos-keyring-[0-9]{8}-[0-9]+-any\.pkg\.tar\.zst')"
MIRRORLIST_PKG="$(pick_latest 'cachyos-mirrorlist-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"
V3_MIRRORLIST_PKG="$(pick_latest 'cachyos-v3-mirrorlist-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"

[[ -n "$KEYRING_PKG" ]] || die "Could not detect cachyos-keyring package from mirror listing."
[[ -n "$MIRRORLIST_PKG" ]] || die "Could not detect cachyos-mirrorlist package from mirror listing."
[[ -n "$V3_MIRRORLIST_PKG" ]] || die "Could not detect cachyos-v3-mirrorlist package from mirror listing."

info "Downloading CachyOS bootstrap packages..."
curl -fL "$CACHY_BASE_URL/$KEYRING_PKG" -o "$TMPDIR/$KEYRING_PKG"
curl -fL "$CACHY_BASE_URL/$MIRRORLIST_PKG" -o "$TMPDIR/$MIRRORLIST_PKG"
curl -fL "$CACHY_BASE_URL/$V3_MIRRORLIST_PKG" -o "$TMPDIR/$V3_MIRRORLIST_PKG"

info "Installing CachyOS keyring/mirrorlists..."
pacman -U --noconfirm \
  "$TMPDIR/$KEYRING_PKG" \
  "$TMPDIR/$MIRRORLIST_PKG" \
  "$TMPDIR/$V3_MIRRORLIST_PKG"

# Insert repos above Arch repos
if ! grep -q '^\[cachyos-v3\]' /etc/pacman.conf; then
  info "Injecting CachyOS repo blocks into /etc/pacman.conf (above [core])"
  CACHY_SNIP=$(cat <<'EOF'
# ---- CachyOS repos (forced x86-64-v3) ----
[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
# -----------------------------------------
EOF
)
  awk -v snip="$CACHY_SNIP" '
    BEGIN{inserted=0}
    /^\[core\]/{ if(inserted==0){print snip; inserted=1} }
    {print}
  ' /etc/pacman.conf > /etc/pacman.conf.new
  mv /etc/pacman.conf.new /etc/pacman.conf
else
  warn "CachyOS repos already present; not duplicating."
fi

info "Syncing databases..."
pacman -Syy --noconfirm

# ---- NVIDIA userspace (CachyOS v3) -------------------------------------------
info "Installing NVIDIA userspace (nvidia-utils + lib32) from CachyOS repos"
pacman -S --noconfirm --needed nvidia-utils || die "Failed to install nvidia-utils"
pacman -S --noconfirm --needed lib32-nvidia-utils || die "lib32-nvidia-utils install failed (check multilib)."

# ---- CachyOS kernel + nvidia-open modules ------------------------------------
info "Installing CachyOS kernel + nvidia-open modules"
pacman -S --noconfirm --needed linux-cachyos linux-cachyos-headers

if pacman -Si linux-cachyos-nvidia-open >/dev/null 2>&1; then
  pacman -S --noconfirm --needed linux-cachyos-nvidia-open
else
  warn "linux-cachyos-nvidia-open not found; you may need DKMS or different kernel flavor."
fi

# ---- mkinitcpio ---------------------------------------------------------------
info "Configuring mkinitcpio for systemd initramfs + sd-encrypt"
sed -i 's/^MODULES=.*/MODULES=(btrfs nvme nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf

info "Building initramfs for all presets"
mkinitcpio -P

info "Enabling NetworkManager"
systemctl enable NetworkManager

info "System configuration complete."
