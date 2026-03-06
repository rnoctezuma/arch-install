#!/bin/bash
set -euo pipefail

echo "================================="
echo "Arch Linux Automated Installer"
echo "================================="

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root."
  exit 1
fi

# Ensure /mnt exists
if [[ ! -d /mnt ]]; then
  echo "/mnt directory not found."
  exit 1
fi

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

  STEP_PATH="$SCRIPT_DIR/steps/$step"

  if [[ ! -f "$STEP_PATH" ]]; then
    echo "Step file not found: $STEP_PATH"
    exit 1
  fi

  if [[ "$step" == "05_system_config.sh" ]]; then

      # Fix DNS inside chroot (important for pacman)
      cp /etc/resolv.conf /mnt/etc/resolv.conf

      # Copy step into new system
      cp "$STEP_PATH" /mnt/root/

      # Execute inside installed system
      arch-chroot /mnt bash "/root/$step"

      # Remove installer script from system
      rm /mnt/root/$step

  else
      bash "$STEP_PATH"
  fi

  echo
  echo "$step completed."

done

echo
echo "================================="
echo "INSTALLATION FINISHED"
echo "================================="
echo
echo "You can now reboot:"
echo
echo "    reboot"
echo
