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
echo "Installing essential packages..."

pacman -S --noconfirm \
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

echo
echo "Adding CachyOS repositories..."

curl -o /etc/pacman.d/cachyos-mirrorlist \
https://mirror.cachyos.org/cachyos-mirrorlist

cat <<EOF >> /etc/pacman.conf

[cachyos-core]
SigLevel = Required DatabaseOptional
Include = /etc/pacman.d/cachyos-mirrorlist

[cachyos-extra]
SigLevel = Required DatabaseOptional
Include = /etc/pacman.d/cachyos-mirrorlist

[cachyos]
SigLevel = Required DatabaseOptional
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

echo
echo "Updating repositories..."

pacman -Sy

echo
echo "Installing CachyOS NVIDIA optimized kernel..."

pacman -S --noconfirm \
linux-cachyos-nvidia \
linux-cachyos-nvidia-headers

echo
echo "Configuring mkinitcpio for LUKS + BTRFS..."

sed -i 's/^MODULES=.*/MODULES=(btrfs nvme xhci_pci)/' /etc/mkinitcpio.conf

sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

echo
echo "Generating initramfs..."

mkinitcpio -P

echo
echo "Enabling essential services..."

systemctl enable NetworkManager

echo
echo "System configuration complete."
