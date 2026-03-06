#!/bin/bash
set -euo pipefail

echo "================================="
echo "Arch Linux Automated Installer"
echo "================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

steps=(
  01_disk.sh
  02_luks.sh
  03_btrfs.sh
  04_base_install.sh
  05_system_config.sh
  06_bootloader.sh
)

for step in "${steps[@]}"; do
  echo
  echo "Running $step"
  echo "---------------------------------"

  if [[ "$step" == "05_system_config.sh" ]]; then
      cp "$SCRIPT_DIR/steps/$step" /mnt/root/
      arch-chroot /mnt bash "/root/$step"
      rm /mnt/root/$step
  else
      bash "$SCRIPT_DIR/steps/$step"
  fi

  echo
  echo "$step completed."
done

echo
echo "================================="
echo "INSTALLATION FINISHED"
echo "You can now reboot."
echo "================================="
