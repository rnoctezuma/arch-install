#!/usr/bin/env bash
set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  # Best-effort cleanup of copied scripts in chroot root.
  if [[ -d /mnt/root ]]; then
    rm -f /mnt/root/01_disk.sh \
          /mnt/root/02_luks.sh \
          /mnt/root/03_btrfs.sh \
          /mnt/root/04_base_install.sh \
          /mnt/root/05_system_config.sh \
          /mnt/root/06_bootloader.sh \
          /mnt/root/07_uefi_entry.sh \
          /mnt/root/08_snapshot_boot_entries.sh \
          /mnt/root/09_snapper_setup.sh \
          /mnt/root/10_snapper_limine_hook.sh 2>/dev/null || true
  fi
  if [[ $ec -ne 0 ]]; then
    warn "Installer failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."
[[ -d /mnt ]] || die "/mnt not found."

require_cmd bash
require_cmd arch-chroot
require_cmd cp
require_cmd mkdir

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Live-ISO steps (operate on /dev, /mnt and build the target filesystem)
steps_live=(
  01_disk.sh
  02_luks.sh
  03_btrfs.sh
  04_base_install.sh
)

# In-chroot steps (operate on the installed system root)
steps_chroot=(
  05_system_config.sh
  06_bootloader.sh
  07_uefi_entry.sh
  08_snapshot_boot_entries.sh
  09_snapper_setup.sh
  10_snapper_limine_hook.sh
)

echo "================================="
echo "Arch Linux Automated Installer"
echo "================================="

# ---- Run live steps -----------------------------------------------------------
for step in "${steps_live[@]}"; do
  STEP_PATH="$SCRIPT_DIR/steps/$step"
  [[ -f "$STEP_PATH" ]] || die "Step file not found: $STEP_PATH"

  echo
  info "Running $step (live ISO)"
  bash "$STEP_PATH"
done

# ---- Copy /tmp state into chroot /tmp ----------------------------------------
mkdir -p /mnt/tmp

for f in /tmp/arch_disk /tmp/arch_mapper /tmp/arch_root_part; do
  [[ -f "$f" ]] || die "Missing state file: $f (previous step failed?)"
  cp -f "$f" "/mnt/tmp/$(basename "$f")"
done

# Ensure DNS works inside chroot (arch-chroot usually helps, but do it explicitly)
if [[ -f /etc/resolv.conf ]]; then
  cp -L /etc/resolv.conf /mnt/etc/resolv.conf || true
fi

# ---- Copy chroot step scripts ONCE (kept until end) --------------------------
mkdir -p /mnt/root
for step in "${steps_chroot[@]}"; do
  STEP_PATH="$SCRIPT_DIR/steps/$step"
  [[ -f "$STEP_PATH" ]] || die "Step file not found: $STEP_PATH"
  cp -f "$STEP_PATH" "/mnt/root/$step"
done

# ---- Run chroot steps ---------------------------------------------------------
for step in "${steps_chroot[@]}"; do
  echo
  info "Running $step (inside installed system)"
  arch-chroot /mnt bash "/root/$step"
done

echo
echo "================================="
echo "INSTALLATION FINISHED"
echo "================================="
echo "You can now reboot."
