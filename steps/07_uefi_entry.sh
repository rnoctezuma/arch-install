#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 07 (optional): Create a UEFI NVRAM boot entry for Limine via efibootmgr
# - Safe + idempotent: does not create duplicates
# - Requires user confirmation
# ==============================================================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  if (( ec != 0 )); then
    warn "Step 07 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "Run inside installed system (chroot)."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI mode required."

require_cmd efibootmgr
require_cmd mountpoint
mountpoint -q /boot || die "/boot not mounted."

STATE_DIR="/root/arch-install-state"

[[ -f "${STATE_DIR}/arch_disk" ]] || die "Missing ${STATE_DIR}/arch_disk"
DISK="$(< "${STATE_DIR}/arch_disk")"
[[ -b "$DISK" ]] || die "Disk not found: $DISK"

LABEL="Arch Linux (Limine)"
LOADER='\\EFI\\BOOT\\BOOTX64.EFI'

# Detect existing entry with same loader path
if efibootmgr -v | grep -qiE "File\\(${LOADER}\\)"; then
  warn "An EFI entry pointing to ${LOADER} already exists. Not creating a duplicate."
  efibootmgr
  exit 0
fi

echo
warn "About to create UEFI NVRAM entry:"
echo " label : $LABEL"
echo " disk  : $DISK"
echo " part  : 1"
echo " loader: \\EFI\\BOOT\\BOOTX64.EFI"
echo
read -rp "Type YES to write NVRAM entry (anything else skips): " CONFIRM
if [[ "${CONFIRM:-}" != "YES" ]]; then
  echo "Skipped. No NVRAM changes were made."
  exit 0
fi

info "Creating UEFI boot entry..."
efibootmgr --create \
  --disk "$DISK" \
  --part 1 \
  --label "$LABEL" \
  --loader '\EFI\BOOT\BOOTX64.EFI' \
  || warn "efibootmgr failed (firmware may block NVRAM writes)."

info "Current UEFI entries:"
efibootmgr
