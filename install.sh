#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="/tmp/arch-install-logs"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

on_error() {
  local exit_code=$?
  local line_no=$1
  local cmd="${2:-unknown}"
  echo
  warn "Installer failed."
  warn "Exit code : $exit_code"
  warn "Line      : $line_no"
  warn "Command   : $cmd"
  warn "Log file  : $LOG_FILE"
  echo
  exit "$exit_code"
}

trap 'on_error $LINENO "$BASH_COMMAND"' ERR

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -eq 0 ]]; then
    info "Installer finished successfully."
    info "Log file: $LOG_FILE"
  fi
}
trap cleanup_on_exit EXIT

echo "================================="
echo "Arch Linux Automated Installer"
echo "================================="
echo "Log file: $LOG_FILE"
echo

[[ ${EUID:-0} -eq 0 ]] || die "This installer must be run as root."
[[ -d /mnt ]] || die "/mnt directory not found."

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
  09_snapper_setup.sh
  10_snapper_limine_hook.sh
)

run_step_live() {
  local step="$1"
  local step_path="$SCRIPT_DIR/steps/$step"

  [[ -f "$step_path" ]] || die "Step file not found: $step_path"

  echo
  echo "---------------------------------"
  info "RUN LIVE STEP: $step"
  echo "---------------------------------"

  bash "$step_path"

  info "STEP COMPLETED: $step"
}

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

  arch-chroot /mnt bash -x "/root/$step"

  info "STEP COMPLETED: $step"
}

info "Preparing target directories..."
mkdir -p /mnt/root /mnt/tmp /mnt/etc

for step in "${steps_live[@]}"; do
  run_step_live "$step"
done

info "Copying installer state files into target system..."
for f in /tmp/arch_disk /tmp/arch_mapper /tmp/arch_root_part; do
  [[ -f "$f" ]] || die "Missing state file: $f"
  cp -f "$f" "/mnt/tmp/$(basename "$f")"
  info "Copied $f -> /mnt/tmp/"
done

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
