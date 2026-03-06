#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing Limine bootloader"

# читаем данные от предыдущих шагов
MAPPER_NAME=$(cat /tmp/arch_mapper)
ROOT_PART=$(cat /tmp/arch_root_part)

# UUID разделов
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid -s UUID -o value /dev/disk/by-partlabel/ESP)

echo "Root UUID: $ROOT_UUID"
echo "Crypt UUID: $CRYPT_UUID"
echo "EFI UUID: $EFI_UUID"

echo "==> Installing Limine"

arch-chroot /mnt pacman -S --noconfirm limine

echo "==> Installing Limine to EFI"

arch-chroot /mnt limine-install

echo "==> Creating Limine config"

cat <<EOF > /mnt/boot/limine.conf
TIMEOUT=3
INTERFACE_RESOLUTION=auto

:Arch Linux
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux
INITRD_PATH=boot:///initramfs-linux.img

CMDLINE=root=/dev/mapper/$MAPPER_NAME \
rd.luks.name=$CRYPT_UUID=$MAPPER_NAME \
rootflags=subvol=@ \
rw quiet loglevel=3 nowatchdog
EOF

echo "==> Limine bootloader configured"
