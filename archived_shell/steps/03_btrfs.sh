#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 03: Btrfs filesystem + subvolumes + mounts + format/mount ESP
# Requires:
#   /tmp/arch_mapper (from step 02)
#   /tmp/arch_disk   (from step 01)
#
# Subvolumes:
#   @, @home, @log, @cache, @snapshots
#
# Mount options:
#   noatime,compress=zstd:1,space_cache=v2,discard=async,commit=120
#
# Note: discard/trim through LUKS requires explicit allow-discards policy.
# ==============================================================================

TMP_ARCH_DISK="/tmp/arch_disk"
TMP_ARCH_MAPPER="/tmp/arch_mapper"

MAPPER=""
DEVICE=""
DISK=""
EFI_PART=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    set +e
    umount -R /mnt >/dev/null 2>&1 || true
    warn "Step 03 failed (exit code $ec). Attempted to unmount /mnt."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."

require_cmd mount
require_cmd umount
require_cmd lsblk
require_cmd sync

if ! command -v mkfs.btrfs >/dev/null 2>&1; then
  require_cmd pacman
  info "Installing btrfs-progs..."
  pacman -S --noconfirm --needed btrfs-progs
fi
require_cmd mkfs.btrfs
require_cmd btrfs

if ! command -v mkfs.fat >/dev/null 2>&1; then
  require_cmd pacman
  info "Installing dosfstools..."
  pacman -S --noconfirm --needed dosfstools
fi
require_cmd mkfs.fat

umount -R /mnt >/dev/null 2>&1 || true

[[ -f "$TMP_ARCH_MAPPER" ]] || die "Missing $TMP_ARCH_MAPPER (run step 02)."
MAPPER="$(<"$TMP_ARCH_MAPPER")"
[[ -n "$MAPPER" ]] || die "$TMP_ARCH_MAPPER is empty."
DEVICE="/dev/mapper/$MAPPER"
[[ -b "$DEVICE" ]] || die "Mapper device not found: $DEVICE"

[[ -f "$TMP_ARCH_DISK" ]] || die "Missing $TMP_ARCH_DISK (run step 01)."
DISK="$(<"$TMP_ARCH_DISK")"
[[ -b "$DISK" ]] || die "Disk not found: $DISK"

EFI_PART="$(lsblk -npo PATH,PARTLABEL "$DISK" | awk '$2=="EFI"{print $1}')"

[[ -b "$EFI_PART" ]] || die "EFI partition not found: $EFI_PART"

info "Creating Btrfs filesystem on $DEVICE ..."
mkfs.btrfs -f -L arch "$DEVICE"
sync

info "Creating Btrfs subvolumes..."
mount "$DEVICE" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@snapshots
umount /mnt || die "Failed to unmount /mnt after subvolume creation"
sync

BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async,commit=120"

info "Mounting final subvolume layout..."
mount -o "${BTRFS_OPTS},subvol=@" "$DEVICE" /mnt

if ! mountpoint -q /mnt; then
  die "Failed to mount /mnt"
fi

mkdir -p /mnt/home /mnt/var/log /mnt/var/cache /mnt/.snapshots /mnt/boot
chmod 750 /mnt/.snapshots

mount -o "${BTRFS_OPTS},subvol=@home"      "$DEVICE" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@log"       "$DEVICE" /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@cache"     "$DEVICE" /mnt/var/cache
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$DEVICE" /mnt/.snapshots

info "Formatting EFI partition as FAT32 and mounting at /mnt/boot..."
mkfs.fat -F32 -n EFI "$EFI_PART"

if ! blkid "$EFI_PART" | grep -q 'TYPE="vfat"'; then
  die "EFI partition not formatted as FAT32"
fi

mount "$EFI_PART" /mnt/boot

sync
echo
info "Subvolumes:"
btrfs subvolume list /mnt || true
echo
info "Block devices:"
lsblk -f
