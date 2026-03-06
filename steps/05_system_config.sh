#!/bin/bash
set -euo pipefail

echo "===================================="
echo "Arch Installer - System Configuration"
echo "===================================="

echo
echo "Setting timezone..."

ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
hwclock --systohc

echo
echo "Configuring locale..."

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen

locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo
echo "Setting hostname..."

read -rp "Enter hostname: " hostname
echo "$hostname" > /etc/hostname

cat <<EOF > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 $hostname.localdomain $hostname
EOF

echo
echo "Setting root password..."
passwd

echo
echo "Creating user..."

read -rp "Enter username: " username
useradd -m -G wheel -s /bin/bash "$username"

passwd "$username"

echo
echo "Enabling sudo for wheel group..."

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo
echo "Installing CachyOS optimized kernel..."

pacman -S --noconfirm curl

curl -o /etc/pacman.d/cachyos-mirrorlist \
https://mirror.cachyos.org/cachyos-mirrorlist

cat <<EOF >> /etc/pacman.conf

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

pacman -Sy

pacman -S --noconfirm \
linux-cachyos \
linux-cachyos-headers

echo
echo "Configuring mkinitcpio for LUKS + BTRFS..."

sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf

sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

echo
echo "Generating initramfs..."

mkinitcpio -P

echo
echo "Enabling essential services..."

systemctl enable NetworkManager

echo
echo "System configuration complete."
