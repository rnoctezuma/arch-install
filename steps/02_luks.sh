#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - LUKS Encryption"
echo "===================================="

# Getting disk from 01_disk.sh step 
DISK=$(cat /tmp/arch_disk)

ROOT_PART="${DISK}p2"

# if it's not NVMe (for example - /sda/)
if [[ "$DISK" != *"nvme"* ]]; then
    ROOT_PART="${DISK}2"
fi

echo
echo "Using root partition: $ROOT_PART"

if [ ! -b "$ROOT_PART" ]; then
    echo "Root partition not found!"
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
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  "$ROOT_PART"

echo
echo "Opening encrypted container..."

cryptsetup open "$ROOT_PART" cryptroot

echo
echo "LUKS container opened as /dev/mapper/cryptroot"

lsblk

echo "cryptroot" > /tmp/arch_mapper
