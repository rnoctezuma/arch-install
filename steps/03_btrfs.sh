#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - BTRFS Setup"
echo "===================================="

# Ensure clean mount point
umount -R /mnt 2>/dev/null || true

# Check 02_luks.sh step was completed successfully
if [ ! -f /tmp/arch_mapper ]; then
    echo "LUKS mapper not found. Run 02_luks.sh first."
    exit 1
fi

MAPPER=$(cat /tmp/arch_mapper)
DEVICE="/dev/mapper/$MAPPER"

if [ ! -b "$DEVICE" ]; then
    echo "Mapper device not found!"
    exit 1
fi

# Ensure btrfs tools exist
command -v mkfs.btrfs >/dev/null || pacman -Sy --noconfirm btrfs-progs

echo
echo "Creating BTRFS filesystem..."

mkfs.btrfs -f -L arch "$DEVICE"

echo
echo "Mounting temporary BTRFS root..."

mount "$DEVICE" /mnt

echo
echo "Creating subvolumes..."

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@snapshots

echo
echo "Unmounting temporary mount..."

umount /mnt

echo
echo "Mounting subvolumes..."

BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async,commit=120"

mount -o $BTRFS_OPTS,subvol=@ "$DEVICE" /mnt

mkdir -p /mnt/{home,var/log,var/cache,.snapshots,boot}

mount -o noatime,compress=zstd,ssd,commit=120,subvol=@home "$DEVICE" /mnt/home
mount -o noatime,compress=zstd,ssd,commit=120,subvol=@log "$DEVICE" /mnt/var/log
mount -o noatime,compress=zstd,ssd,commit=120,subvol=@cache "$DEVICE" /mnt/var/cache
mount -o noatime,compress=zstd,ssd,commit=120,subvol=@snapshots "$DEVICE" /mnt/.snapshots

echo
echo "Subvolumes created:"
btrfs subvolume list /mnt

echo
echo "BTRFS layout ready."

lsblk
