#!/bin/bash
set -e

echo "===================================="
echo "Arch Installer - Disk Partitioning"
echo "===================================="

echo
echo "Available disks:"
echo

lsblk -dpnoNAME,SIZE,MODEL | grep -E "sd|nvme|vd"

echo
read -rp "Enter disk to use (example: /dev/nvme0n1): " DISK

if [ ! -b "$DISK" ]; then
    echo "Disk not found!"
    exit 1
fi

echo
echo "WARNING: This will erase ALL data on $DISK"
read -rp "Type YES to continue: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo
echo "Creating partition table..."

parted -s "$DISK" mklabel gpt

echo
echo "Creating EFI partition..."

parted -s "$DISK" mkpart EFI fat32 1MiB 2049MiB
parted -s "$DISK" set 1 esp on

echo
echo "Creating ROOT partition..."

parted -s "$DISK" mkpart ROOT btrfs 2049MiB 100%

echo
echo "Partitioning complete."

sleep 2

echo
echo "Result:"
lsblk "$DISK"
