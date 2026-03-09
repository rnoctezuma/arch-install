#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 05: System configuration inside the installed system (arch-chroot /mnt)
#
# Target machine: Lenovo Legion i7 Pro Gen10 / Intel CPU / NVIDIA RTX 5080 Laptop
# Constraints:
#   - UEFI-only path (handled by step01/06)
#   - CachyOS repos: x86-64-v3 (v4 requires AVX-512; follow CachyOS docs)
#   - Install CachyOS kernel + nvidia-open modules:
#       linux-cachyos-nvidia-open + linux-cachyos-headers
#     (with fallback if package absent)
#
# mkinitcpio:
#   Use upstream mkinitcpio encrypted-root systemd-initramfs example:
#   HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
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
    warn "Step 05 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root (inside chroot)."

require_cmd pacman
require_cmd sed
require_cmd locale-gen
require_cmd mkinitcpio
require_cmd systemctl

# ---- Basic system settings ----------------------------------------------------

info "Setting timezone: Asia/Ho_Chi_Minh"
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
hwclock --systohc

info "Configuring locale: en_US.UTF-8"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf "LANG=en_US.UTF-8\n" > /etc/locale.conf

info "Setting hostname"
read -rp "Enter hostname: " hostname
[[ -n "${hostname:-}" ]] || die "Hostname cannot be empty."
printf "%s\n" "$hostname" > /etc/hostname

cat <<EOF > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${hostname}.localdomain ${hostname}
EOF

info "Set root password"
passwd

info "Creating user"
read -rp "Enter username: " username
[[ -n "${username:-}" ]] || die "Username cannot be empty."
if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  die "Invalid username: $username"
fi

useradd -m -G wheel -s /bin/bash "$username"
passwd "$username"

info "Enabling sudo for wheel group (safer via sudoers.d)"
install -d -m 0755 /etc/sudoers.d
printf "%%wheel ALL=(ALL:ALL) ALL\n" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# ---- Pacman basics ------------------------------------------------------------

info "Enabling multilib (needed for many gaming 32-bit libs)"
# Uncomment [multilib] block if present and commented
sed -i 's/^[[:space:]]*#\[\s*multilib\s*\]/[multilib]/' /etc/pacman.conf
sed -i 's/^[[:space:]]*#Include = \/etc\/pacman.d\/mirrorlist/Include = \/etc\/pacman.d\/mirrorlist/' /etc/pacman.conf

info "Installing essential packages (Intel + NVIDIA stack baseline)"
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

# We install NVIDIA userspace now; kernel-side modules come from CachyOS packages.
# lib32-nvidia-utils requires multilib enabled above.
pacman -S --noconfirm --needed \
  nvidia-utils \
  lib32-nvidia-utils || warn "Could not install lib32-nvidia-utils (check multilib)."

# ---- Add CachyOS repositories (x86-64-v3) ------------------------------------

info "Adding CachyOS repos (x86-64-v3) per CachyOS docs"
require_cmd pacman-key

# Ensure pacman keyring exists
if [[ ! -d /etc/pacman.d/gnupg ]]; then
  info "Initializing pacman keyring..."
  pacman-key --init
  pacman-key --populate archlinux
fi

# Import + locally sign CachyOS repo key
CACHY_KEY="F3B607488DB35A47"
pacman-key --recv-keys "$CACHY_KEY" --keyserver keyserver.ubuntu.com
pacman-key --lsign-key "$CACHY_KEY"

# Download latest keyring + mirrorlist packages from the CachyOS repo directory
CACHY_BASE_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
TMPDIR="$(mktemp -d)"
cleanup_tmp() { rm -rf "$TMPDIR" >/dev/null 2>&1 || true; }
trap cleanup_tmp EXIT

info "Fetching CachyOS repo directory listing to select latest keyring/mirrorlists..."
LISTING="$(curl -fsSL "$CACHY_BASE_URL/")" || die "Failed to fetch $CACHY_BASE_URL/"

pick_latest() {
  local pattern="$1"
  echo "$LISTING" \
    | grep -oE "$pattern" \
    | sort -V \
    | tail -n 1
}

KEYRING_PKG="$(pick_latest 'cachyos-keyring-[0-9]{8}-[0-9]+-any\.pkg\.tar\.zst')"
MIRRORLIST_PKG="$(pick_latest 'cachyos-mirrorlist-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"
V3_MIRRORLIST_PKG="$(pick_latest 'cachyos-v3-mirrorlist-[0-9]+-[0-9]+-any\.pkg\.tar\.zst')"

[[ -n "$KEYRING_PKG" ]] || die "Could not detect cachyos-keyring package name from listing."
[[ -n "$MIRRORLIST_PKG" ]] || die "Could not detect cachyos-mirrorlist package name from listing."
[[ -n "$V3_MIRRORLIST_PKG" ]] || die "Could not detect cachyos-v3-mirrorlist package name from listing."

info "Downloading:"
info "  $KEYRING_PKG"
info "  $MIRRORLIST_PKG"
info "  $V3_MIRRORLIST_PKG"

curl -fL "$CACHY_BASE_URL/$KEYRING_PKG" -o "$TMPDIR/$KEYRING_PKG"
curl -fL "$CACHY_BASE_URL/$MIRRORLIST_PKG" -o "$TMPDIR/$MIRRORLIST_PKG"
curl -fL "$CACHY_BASE_URL/$V3_MIRRORLIST_PKG" -o "$TMPDIR/$V3_MIRRORLIST_PKG"

pacman -U --noconfirm \
  "$TMPDIR/$KEYRING_PKG" \
  "$TMPDIR/$MIRRORLIST_PKG" \
  "$TMPDIR/$V3_MIRRORLIST_PKG"

# Insert repos above Arch repos by inserting before first non-[options] repo block.
if ! grep -q '^\[cachyos-v3\]' /etc/pacman.conf; then
  info "Adding CachyOS repo blocks to /etc/pacman.conf"
  CACHY_SNIP=$(cat <<'EOF'
# ---- CachyOS repos (x86-64-v3) ----
[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

# Keep [cachyos] as documented by CachyOS
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
# -------------------------------
EOF
)
  awk -v snip="$CACHY_SNIP" '
    BEGIN{inserted=0}
    /^\[options\]/{print; next}
    /^\[.*\]/{ if(inserted==0){print snip; inserted=1} }
    {print}
  ' /etc/pacman.conf > /etc/pacman.conf.new
  mv /etc/pacman.conf.new /etc/pacman.conf
else
  warn "CachyOS repos already present in /etc/pacman.conf; not duplicating."
fi

info "Updating package databases..."
pacman -Sy --noconfirm

# ---- Install CachyOS kernel + NVIDIA open modules ----------------------------

info "Installing CachyOS kernel + nvidia-open modules (preferred)"
if pacman -Si linux-cachyos-nvidia-open >/dev/null 2>&1; then
  pacman -S --noconfirm --needed linux-cachyos-nvidia-open linux-cachyos-headers
else
  warn "linux-cachyos-nvidia-open not found in current repos; falling back to linux-cachyos."
  pacman -S --noconfirm --needed linux-cachyos linux-cachyos-headers
fi

# ---- mkinitcpio: systemd initramfs + sd-encrypt + btrfs ----------------------

info "Configuring mkinitcpio for systemd initramfs + sd-encrypt + Btrfs"
# Keep MODULES minimal; rely on autodetect, but make sure btrfs/nvme are present
sed -i 's/^MODULES=.*/MODULES=(btrfs nvme)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

info "Building initramfs for all installed kernels (mkinitcpio -P)"
mkinitcpio -P

info "Enabling NetworkManager"
systemctl enable NetworkManager

info "System configuration complete."
