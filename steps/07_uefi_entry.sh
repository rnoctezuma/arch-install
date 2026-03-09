#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -d /sys/firmware/efi/efivars ]] || die "Not in UEFI mode"
mountpoint -q /boot || die "/boot not mounted"

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require_cmd efibootmgr

[[ -f /tmp/arch_disk ]] || die "Missing /tmp/arch_disk"

DISK="$(< /tmp/arch_disk)"

PART=1

info "Creating UEFI boot entry..."

efibootmgr --create \
  --disk "$DISK" \
  --part "$PART" \
  --label "Arch Linux (Limine)" \
  --loader '\EFI\BOOT\BOOTX64.EFI' \
  || warn "efibootmgr failed (firmware may block writes)"

info "Current UEFI entries:"
efibootmgr

info "UEFI entry setup complete."
