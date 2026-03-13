#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 06: Install Limine (UEFI-only) + generate limine.conf (Limine v10)
# Runs INSIDE arch-chroot.
#
# UEFI method: copy BOOTX64.EFI to ESP:/EFI/BOOT/BOOTX64.EFI and place
# limine.conf alongside it (highest priority location for EFI-booted Limine).
# ==============================================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  if (( ec != 0 )); then
    warn "Step 06 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root (inside chroot)."
[[ -f /etc/arch-release ]] || die "Not inside installed system."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI mode required (/sys/firmware/efi/efivars missing)."

require_cmd pacman
require_cmd blkid
require_cmd find
require_cmd mountpoint
require_cmd sync

mountpoint -q /boot || die "/boot is not mounted (ESP missing)."

# State files copied by install.sh into chroot /tmp
[[ -f /tmp/arch_mapper ]] || die "Missing /tmp/arch_mapper"
[[ -f /tmp/arch_root_part ]] || die "Missing /tmp/arch_root_part"

MAPPER="$(< /tmp/arch_mapper)"
ROOT_PART="$(< /tmp/arch_root_part)"
[[ -n "$MAPPER" ]] || die "Mapper name empty."
[[ -b "$ROOT_PART" ]] || die "Root partition not found: $ROOT_PART"

CRYPT_UUID="$(blkid -s UUID -o value "$ROOT_PART" || true)"
[[ -n "$CRYPT_UUID" ]] || die "Failed to detect LUKS UUID via blkid."

info "Installing Limine..."
pacman -S --noconfirm --needed limine

EFI_SRC="/usr/share/limine/BOOTX64.EFI"
if [[ ! -f "$EFI_SRC" ]]; then
  EFI_SRC="$(find /usr/share -maxdepth 4 -type f -iname 'bootx64.efi' -print -quit 2>/dev/null || true)"
fi
[[ -f "${EFI_SRC:-}" ]] || die "BOOTX64.EFI not found after installing limine."

ESP_EFI_DIR="/boot/EFI/BOOT"
mkdir -p "$ESP_EFI_DIR"

info "Copying Limine UEFI executable to ESP..."
cp -f "$EFI_SRC" "$ESP_EFI_DIR/BOOTX64.EFI"
sync

pick_first_existing() {
  local f
  for f in "$@"; do
    [[ -f "/boot/$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

KERNEL_FILE="$(pick_first_existing \
  vmlinuz-linux-zen \
  vmlinuz-linux \
  vmlinuz-linux-lts \
)"
[[ -n "$KERNEL_FILE" ]] || die "No supported Arch kernel found in /boot. Did step 04 install one?"

PRESET="${KERNEL_FILE#vmlinuz-}"
INITRAMFS_FILE="initramfs-${PRESET}.img"
FALLBACK_INITRAMFS_FILE="initramfs-${PRESET}-fallback.img"

[[ -f "/boot/$INITRAMFS_FILE" ]] || die "Missing /boot/$INITRAMFS_FILE"

UCODE_LINE=""
if [[ -f /boot/intel-ucode.img ]]; then
  UCODE_LINE="    module_path: boot():/intel-ucode.img"
fi

CMDLINE_BASE="root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rd.luks.options=${CRYPT_UUID}=discard rootflags=subvol=@ rw quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0"

LIMINE_CONF="${ESP_EFI_DIR}/limine.conf"
info "Writing Limine v10 config to $LIMINE_CONF"

cat > "$LIMINE_CONF" <<EOF
# Limine v10 configuration (UEFI)
# Location: /EFI/BOOT/limine.conf (highest priority for EFI-booted Limine)

timeout: 1
quiet: yes
editor_enabled: no

/Arch Linux (${PRESET})
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
${UCODE_LINE}
    module_path: boot():/${INITRAMFS_FILE}
    cmdline: ${CMDLINE_BASE}

/Arch Linux (${PRESET}, fallback initramfs)
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
${UCODE_LINE}
    module_path: boot():/$( [[ -f "/boot/$FALLBACK_INITRAMFS_FILE" ]] && echo "$FALLBACK_INITRAMFS_FILE" || echo "$INITRAMFS_FILE" )
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rd.luks.options=${CRYPT_UUID}=discard rootflags=subvol=@ rw

/Arch Linux (rescue)
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
${UCODE_LINE}
    module_path: boot():/${INITRAMFS_FILE}
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rd.luks.options=${CRYPT_UUID}=discard rootflags=subvol=@ rw systemd.unit=emergency.target

# --- SNAPSHOT AUTO START ---
# (Step 08 will replace the block between START/END)
# --- SNAPSHOT AUTO END ---
EOF

sync
info "Limine installed."
