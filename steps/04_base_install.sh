#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - Base System"
echo "===================================="

# Ensure root filesystem is mounted
if ! mountpoint -q /mnt; then
    echo "/mnt is not mounted. Run previous steps first."
    exit 1
fi

echo
echo "Updating pacman keyring..."

pacman -Sy --noconfirm archlinux-keyring

echo
echo "Optimizing pacman configuration..."

sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

grep -q ILoveCandy /etc/pacman.conf || sed -i '/Color/a ILoveCandy' /etc/pacman.conf

echo
echo "Installing reflector..."

pacman -S --noconfirm --needed reflector

echo
echo "Selecting fastest mirrors..."

reflector \
  --country Vietnam,Singapore,Japan,South\ Korea \
  --age 12 \
  --protocol https \
  --sort rate \
  --latest 20 \
  --save /etc/pacman.d/mirrorlist

echo
echo "Installing base system..."

pacstrap /mnt \
  base \
  base-devel \
  linux-firmware \
  btrfs-progs \
  networkmanager \
  sudo \
  intel-ucode

echo
echo "Generating fstab..."

genfstab -U /mnt > /mnt/etc/fstab

echo
echo "Generated fstab:"
echo "--------------------------------"
cat /mnt/etc/fstab
echo "--------------------------------"

echo
echo "Base system installation complete."
