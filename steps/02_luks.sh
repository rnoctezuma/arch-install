#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - LUKS Encryption"
echo "===================================="

# Check 01_disk.sh step was completed successfully
if [ ! -f /tmp/arch_disk ]; then
    echo "Disk info not found. Run 01_disk.sh first."
    exit 1
fi

# Getting disk from 01_disk.sh
DISK=$(cat /tmp/arch_disk)

# Wait until kernel sees new partitions
udevadm settle

# Detect root partition
if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
    ROOT_PART="${DISK}p2"
else
    ROOT_PART="${DISK}2"
fi

echo
echo "Using root partition: $ROOT_PART"

if [ ! -b "$ROOT_PART" ]; then
    echo "Root partition not found!"
    lsblk "$DISK"
    exit 1
fi

echo
echo "About to encrypt $ROOT_PART"
read -rp "Type YES to continue: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo
echo "Creating LUKS2 container..."

cryptsetup luksFormat \
  --type luks2 \
  --label cryptroot \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  --pbkdf-memory 1048576 \
  --pbkdf-parallel 4 \
  --iter-time 2000 \
  --verify-passphrase \
  "$ROOT_PART"

echo
echo "Opening encrypted container..."

cryptsetup open "$ROOT_PART" cryptroot

echo
echo "LUKS container opened as /dev/mapper/cryptroot"

lsblk "$DISK"

echo "cryptroot" > /tmp/arch_mapper
echo "$ROOT_PART" > /tmp/arch_root_part
