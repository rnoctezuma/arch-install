#!/bin/bash
set -euo pipefail

echo "================================="
echo "Arch Linux Automated Installer"
echo "================================="

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -d /mnt ]] || { echo "/mnt not found."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

steps_live=(
  01_disk.sh
  02_luks.sh
  03_btrfs.sh
  04_base_install.sh
)

steps_chroot=(
  05_system_config.sh
  06_bootloader.sh
  07_uefi_entry.sh
  08_snapshot_boot_entries.sh
)

# ---- live steps ----
for step in "${steps_live[@]}"; do
  echo
  echo "Running $step"
  bash "$SCRIPT_DIR/steps/$step"
done

# prepare state files for chroot
mkdir -p /mnt/tmp
cp /tmp/arch_* /mnt/tmp/

# ensure DNS works inside chroot
cp /etc/resolv.conf /mnt/etc/resolv.conf

# ---- chroot steps ----
for step in "${steps_chroot[@]}"; do
  echo
  echo "Running $step (inside chroot)"
  cp "$SCRIPT_DIR/steps/$step" "/mnt/root/$step"
  arch-chroot /mnt bash "/root/$step"
  rm -f "/mnt/root/$step"
done

echo
echo "================================="
echo "INSTALLATION FINISHED"
echo "================================="
echo "You can now reboot."
