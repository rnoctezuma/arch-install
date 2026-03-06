#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - Base System"
echo "===================================="

if [ ! -d /mnt ]; then
    echo "/mnt not mounted. Run previous steps first."
    exit 1
fi

echo
echo "Updating pacman..."

pacman -Sy --noconfirm archlinux-keyring

echo
echo "Optimizing pacman configuration..."

sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

grep -q ILoveCandy /etc/pacman.conf || sed -i '/Color/a ILoveCandy' /etc/pacman.conf

echo
echo "Selecting fastest mirrors..."

pacman -S --noconfirm reflector

reflector \
  --country Vietnam,Singapore,Japan,South Korea \
  --age 12 \
  --protocol https \
  --sort rate \
  --save /etc/pacman.d/mirrorlist

echo
echo "Installing base system..."

pacstrap /mnt \
  base \
  base-devel \
  linux \
  linux-headers \
  linux-firmware \
  btrfs-progs \
  networkmanager \
  sudo \
  nano \
  git \
  reflector \
  intel-ucode

echo
echo "Generating fstab..."

genfstab -U /mnt >> /mnt/etc/fstab

echo
echo "Generated fstab:"
echo "--------------------------------"
cat /mnt/etc/fstab
echo "--------------------------------"

echo
echo "Base system installation complete."
