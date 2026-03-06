#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - Limine Bootloader"
echo "===================================="

echo
echo "Installing Limine..."

pacman -S --noconfirm limine

echo
echo "Installing Limine to EFI..."

mkdir -p /boot/EFI/BOOT

cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
cp /usr/share/limine/limine.conf /boot/limine.conf || true

echo
echo "Detecting UUID..."

CRYPTUUID=$(blkid -s UUID -o value $(blkid | grep crypto_LUKS | cut -d: -f1))

echo "LUKS UUID: $CRYPTUUID"

echo
echo "Creating Limine configuration..."

cat <<EOF > /boot/limine.conf
TIMEOUT=5
DEFAULT_ENTRY=Arch Linux

:Arch Linux

PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux-cachyos-nvidia
INITRD_PATH=boot:///initramfs-linux-cachyos-nvidia.img

CMDLINE=root=/dev/mapper/cryptroot rw rootflags=subvol=@ cryptdevice=UUID=$CRYPTUUID:cryptroot
EOF

echo
echo "Limine configuration created."

echo
echo "Installed files:"
ls /boot

echo
echo "Bootloader installation complete."
