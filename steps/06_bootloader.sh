#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 06: Install Limine (UEFI-only) + generate limine.conf
# Runs STRICTLY inside arch-chroot.
# ==============================================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    warn "Step 06 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

# ------------------------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------------------------

[[ ${EUID:-0} -eq 0 ]] || die "Must be run as root (inside chroot)."
[[ -f /etc/arch-release ]] || die "Not inside installed system (arch-chroot missing)."

# UEFI check
[[ -d /sys/firmware/efi/efivars ]] || die "System not booted in UEFI mode."

# /boot must be mounted (ESP)
mountpoint -q /boot || die "/boot is not mounted (ESP missing)."

# State files (copied by install.sh into chroot /tmp)
[[ -f /tmp/arch_disk ]] || die "Missing /tmp/arch_disk"
[[ -f /tmp/arch_mapper ]] || die "Missing /tmp/arch_mapper"
[[ -f /tmp/arch_root_part ]] || die "Missing /tmp/arch_root_part"

DISK="$(< /tmp/arch_disk)"
MAPPER="$(< /tmp/arch_mapper)"
ROOT_PART="$(< /tmp/arch_root_part)"

[[ -b "$DISK" ]] || die "Disk not found: $DISK"
[[ -b "$ROOT_PART" ]] || die "Root partition not found: $ROOT_PART"
[[ -n "$MAPPER" ]] || die "Mapper name empty."

CRYPT_UUID="$(blkid -s UUID -o value "$ROOT_PART" || true)"
[[ -n "$CRYPT_UUID" ]] || die "Could not read UUID of LUKS partition."

info "Disk: $DISK"
info "Mapper: $MAPPER"
info "LUKS UUID: $CRYPT_UUID"

# ------------------------------------------------------------------------------
# Install Limine
# ------------------------------------------------------------------------------

info "Installing Limine package..."
pacman -S --noconfirm --needed limine

EFI_SRC="/usr/share/limine/BOOTX64.EFI"

if [[ ! -f "$EFI_SRC" ]]; then
  EFI_SRC="$(find /usr/share -maxdepth 3 -type f -iname 'bootx64.efi' 2>/dev/null | head -n1 || true)"
fi

[[ -f "${EFI_SRC:-}" ]] || die "BOOTX64.EFI not found after installing limine."

ESP_EFI_DIR="/boot/EFI/BOOT"
mkdir -p "$ESP_EFI_DIR"

info "Copying BOOTX64.EFI to ESP..."
cp -f "$EFI_SRC" "$ESP_EFI_DIR/BOOTX64.EFI"
sync

# ------------------------------------------------------------------------------
# Kernel detection (robust)
# ------------------------------------------------------------------------------

pick_first_existing() {
  local f
  for f in "$@"; do
    if [[ -f "/boot/$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

KERNEL_FILE="$(pick_first_existing \
  vmlinuz-linux-cachyos-nvidia-open \
  vmlinuz-linux-cachyos-nvidia \
  vmlinuz-linux-cachyos \
  vmlinuz-linux \
)" || die "No supported kernel found in /boot."

PRESET="${KERNEL_FILE#vmlinuz-}"
INITRAMFS_FILE="initramfs-${PRESET}.img"
FALLBACK_INITRAMFS_FILE="initramfs-${PRESET}-fallback.img"

[[ -f "/boot/$INITRAMFS_FILE" ]] || die "Missing /boot/$INITRAMFS_FILE"

if [[ -f "/boot/$FALLBACK_INITRAMFS_FILE" ]]; then
  FALLBACK_MODULE_PATH="$FALLBACK_INITRAMFS_FILE"
else
  warn "Fallback initramfs not found, using normal initramfs."
  FALLBACK_MODULE_PATH="$INITRAMFS_FILE"
fi

# ------------------------------------------------------------------------------
# Microcode handling
# ------------------------------------------------------------------------------

UCODE_LINE=""
if [[ -f "/boot/intel-ucode.img" ]]; then
  UCODE_LINE="    module_path: boot():/intel-ucode.img"
fi

# ------------------------------------------------------------------------------
# Kernel cmdline
# ------------------------------------------------------------------------------

CMDLINE_BASE="root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rootflags=subvol=@ rw quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0"

# ------------------------------------------------------------------------------
# Write Limine config (v10 syntax)
# ------------------------------------------------------------------------------

info "Writing Limine configuration..."

LIMINE_CONF="${ESP_EFI_DIR}/limine.conf"

cat > "$LIMINE_CONF" <<EOF
# Limine v10 configuration (UEFI)
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
    module_path: boot():/${FALLBACK_MODULE_PATH}
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rootflags=subvol=@ rw

/Arch Linux (Btrfs snapshots container)
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
${UCODE_LINE}
    module_path: boot():/${INITRAMFS_FILE}
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rootflags=subvol=@snapshots rw

/Arch Linux (rescue)
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
${UCODE_LINE}
    module_path: boot():/${INITRAMFS_FILE}
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rw systemd.unit=emergency.target
EOF

sync

# ------------------------------------------------------------------------------
# Debug output
# ------------------------------------------------------------------------------

echo
info "/boot contents:"
ls -lh /boot
echo
info "EFI/BOOT contents:"
ls -lh "$ESP_EFI_DIR"
echo
info "Limine installation complete."
