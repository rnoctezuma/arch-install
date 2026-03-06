#!/usr/bin/env bash
set -e

echo "Installing Limine bootloader..."

DISK=$(cat /tmp/arch_disk)
MAPPER_NAME=$(cat /tmp/arch_mapper)
ROOT_PART=$(cat /tmp/arch_root_part)

CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

echo "Disk: $DISK"
echo "Mapper: $MAPPER_NAME"
echo "LUKS UUID: $CRYPT_UUID"

echo
echo "Installing Limine..."

arch-chroot /mnt pacman -S --noconfirm limine

echo
echo "Installing Limine to disk..."

arch-chroot /mnt limine-install "$DISK"

echo
echo "Creating Limine configuration..."

cat <<EOF > /mnt/boot/limine.conf
TIMEOUT=1
INTERFACE_RESOLUTION=auto
QUIET=yes
EDITOR_ENABLED=no

:Arch Linux (CachyOS NVIDIA Kernel)
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux-cachyos-nvidia
INITRD_PATH=boot:///intel-ucode.img
INITRD_PATH=boot:///initramfs-linux-cachyos-nvidia.img

CMDLINE=root=/dev/mapper/$MAPPER_NAME rd.luks.name=$CRYPT_UUID=$MAPPER_NAME rootflags=subvol=@ rw quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0

:Arch Linux (Fallback Initramfs)
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux-cachyos-nvidia
INITRD_PATH=boot:///intel-ucode.img
INITRD_PATH=boot:///initramfs-linux-cachyos-nvidia-fallback.img

CMDLINE=root=/dev/mapper/$MAPPER_NAME rd.luks.name=$CRYPT_UUID=$MAPPER_NAME rootflags=subvol=@ rw

:Arch Linux (BTRFS Snapshot)
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux-cachyos-nvidia
INITRD_PATH=boot:///intel-ucode.img
INITRD_PATH=boot:///initramfs-linux-cachyos-nvidia.img

CMDLINE=root=/dev/mapper/$MAPPER_NAME rd.luks.name=$CRYPT_UUID=$MAPPER_NAME rootflags=subvol=@snapshots rw

:Arch Linux (Rescue Mode)
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux-cachyos-nvidia
INITRD_PATH=boot:///intel-ucode.img
INITRD_PATH=boot:///initramfs-linux-cachyos-nvidia.img

CMDLINE=root=/dev/mapper/$MAPPER_NAME rd.luks.name=$CRYPT_UUID=$MAPPER_NAME rw systemd.unit=emergency.target
EOF

echo
echo "Bootloader installation completed."
ls -lh /mnt/boot
