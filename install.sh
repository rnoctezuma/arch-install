#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/arch-install"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

die() { echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

cleanup_on_exit() {
  ec=$?
  if (( ec == 0 )); then
    info "Installer finished successfully."
  else
    warn "Installer exited with error code $ec"
  fi
  info "Log file: $LOG_FILE"
}
trap cleanup_on_exit EXIT

[[ $EUID -eq 0 ]] || die "This installer must be run as root."
[[ -d /mnt ]] || die "/mnt directory not found."

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

require_cmd arch-chroot
require_cmd cp
require_cmd chmod
require_cmd tee
require_cmd date
require_cmd mkdir

run_step_live() {
  local step="$1"
  local path="$SCRIPT_DIR/steps/$step"

  [[ -f "$path" ]] || die "Missing step: $step"

  echo
  info "RUN LIVE STEP: $step"

  if ! bash "$path"; then
    die "Step failed: $step"
  fi

  info "STEP COMPLETED: $step"
}

echo "================================="
echo "Arch Linux Automated Installer"
echo "================================="
echo "Log file: $LOG_FILE"
echo

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
  09_snapper_setup.sh
  10_snapper_limine_hook.sh
)

run_step_chroot() {
  local step="$1"
  local step_path="$SCRIPT_DIR/steps/$step"

  [[ -f "$step_path" ]] || die "Step file not found: $step_path"

  echo
  echo "---------------------------------"
  info "RUN CHROOT STEP: $step"
  echo "---------------------------------"

  cp -f "$step_path" "/mnt/root/$step"
  chmod +x "/mnt/root/$step"

  info "Copied to /mnt/root/$step"

  if ! arch-chroot /mnt bash "/root/$step"; then
    die "Chroot step failed: $step"
  fi

  rm -f "/mnt/root/$step" || true
  info "STEP COMPLETED: $step"
}

info "Preparing target directories..."
mkdir -p /mnt/root /mnt/etc "$STATE_DIR_TARGET"

for step in "${steps_live[@]}"; do
  run_step_live "$step"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR_TARGET="/mnt/root/arch-install-state"

info "Copying installer state files into target system..."
for f in /tmp/arch_disk /tmp/arch_mapper /tmp/arch_root_part; do
  [[ -f "$f" ]] || die "Missing state file: $f"
  cp -f "$f" "${STATE_DIR_TARGET}/$(basename "$f")"
  info "Copied $f -> ${STATE_DIR_TARGET}/"
done

SNAPSHOT_GENERATOR="$SCRIPT_DIR/steps/08_snapshot_boot_entries.sh"
[[ -f "$SNAPSHOT_GENERATOR" ]] || die "Missing step file: $SNAPSHOT_GENERATOR"
cp -f "$SNAPSHOT_GENERATOR" "${STATE_DIR_TARGET}/08_snapshot_boot_entries.sh"
chmod 0755 "${STATE_DIR_TARGET}/08_snapshot_boot_entries.sh"
info "Copied $SNAPSHOT_GENERATOR -> ${STATE_DIR_TARGET}/08_snapshot_boot_entries.sh"

if [[ -f /etc/resolv.conf ]]; then
  info "Copying resolv.conf into target..."
  cp -L /etc/resolv.conf /mnt/etc/resolv.conf
fi

for step in "${steps_chroot[@]}"; do
  run_step_chroot "$step"
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
