#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 06: Install Limine (UEFI-only) + generate limine.conf for encrypted Btrfs
#
# This script runs OUTSIDE chroot but operates on /mnt and uses arch-chroot.
#
# Current Arch package: limine 10.x (config syntax uses 'timeout:' and '/Entry'
# lines). We generate Limine v10 compatible config.
#
# UEFI install method (upstream):
#   Copy BOOTX64.EFI to ESP:/EFI/BOOT/BOOTX64.EFI
#   Place limine.conf in the EFI app path (same directory) to be preferred.
#
# Contract:
#   Reads /tmp/arch_disk, /tmp/arch_mapper, /tmp/arch_root_part
# ==============================================================================

TMP_ARCH_DISK="/tmp/arch_disk"
TMP_ARCH_MAPPER="/tmp/arch_mapper"
TMP_ARCH_ROOT_PART="/tmp/arch_root_part"

DISK=""
MAPPER=""
ROOT_PART=""
CRYPT_UUID=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    warn "Step 06 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root."

# UEFI-only sanity check (Limine UEFI path)
if [[ ! -d /sys/firmware/efi/efivars ]]; then
  die "Not running in UEFI mode (/sys/firmware/efi/efivars missing). Boot ISO in UEFI mode."
fi

require_cmd arch-chroot
require_cmd blkid
require_cmd lsblk
require_cmd find
require_cmd sync
require_cmd mountpoint

mountpoint -q /mnt || die "/mnt is not mounted. Run step 03/04 first."
mountpoint -q /mnt/boot || die "/mnt/boot (ESP) is not mounted. Run step 03 first."

[[ -f "$TMP_ARCH_DISK" ]] || die "Missing $TMP_ARCH_DISK"
[[ -f "$TMP_ARCH_MAPPER" ]] || die "Missing $TMP_ARCH_MAPPER"
[[ -f "$TMP_ARCH_ROOT_PART" ]] || die "Missing $TMP_ARCH_ROOT_PART"

DISK="$(<"$TMP_ARCH_DISK")"
MAPPER="$(<"$TMP_ARCH_MAPPER")"
ROOT_PART="$(<"$TMP_ARCH_ROOT_PART")"

[[ -b "$DISK" ]] || die "Disk not found: $DISK"
[[ -b "$ROOT_PART" ]] || die "Root partition not found: $ROOT_PART"
[[ -n "$MAPPER" ]] || die "Mapper name empty."

CRYPT_UUID="$(blkid -s UUID -o value "$ROOT_PART" || true)"
[[ -n "$CRYPT_UUID" ]] || die "Could not read UUID of LUKS partition: $ROOT_PART"

info "Disk: $DISK"
info "Mapper: $MAPPER"
info "LUKS UUID: $CRYPT_UUID"

info "Installing Limine inside target system..."
arch-chroot /mnt pacman -S --noconfirm --needed limine

# Locate BOOTX64.EFI from installed limine package (Arch places it in /usr/share/limine)
EFI_SRC="/mnt/usr/share/limine/BOOTX64.EFI"
if [[ ! -f "$EFI_SRC" ]]; then
  # Fallback: try to find it
  EFI_SRC="$(find /mnt/usr/share -maxdepth 3 -type f -iname 'bootx64.efi' 2>/dev/null | head -n 1 || true)"
fi
[[ -f "${EFI_SRC:-}" ]] || die "Could not locate BOOTX64.EFI under /mnt/usr/share (is limine installed?)."

ESP_EFI_DIR="/mnt/boot/EFI/BOOT"
mkdir -p "$ESP_EFI_DIR"

info "Copying Limine UEFI executable to ESP..."
cp -f "$EFI_SRC" "$ESP_EFI_DIR/BOOTX64.EFI"
sync

# Detect kernel/initramfs artifacts on ESP (/mnt/boot)
pick_first_existing() {
  local f
  for f in "$@"; do
    if [[ -f "/mnt/boot/$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

KERNEL_FILE="$(pick_first_existing \
  vmlinuz-linux-cachyos \
  vmlinuz-linux-cachyos-nvidia \
  vmlinuz-linux \
  )" || die "No kernel image found in /mnt/boot. Did step 05 install a kernel?"

# Derive preset suffix from vmlinuz-*
PRESET="${KERNEL_FILE#vmlinuz-}"
INITRAMFS_FILE="initramfs-${PRESET}.img"
FALLBACK_INITRAMFS_FILE="initramfs-${PRESET}-fallback.img"

# Optional microcode
UCODE_LINE=""
if [[ -f "/mnt/boot/intel-ucode.img" ]]; then
  UCODE_LINE="    module_path: boot():/intel-ucode.img"
fi

# Validate initramfs existence
[[ -f "/mnt/boot/$INITRAMFS_FILE" ]] || die "Missing /mnt/boot/$INITRAMFS_FILE (mkinitcpio -P should create it)."

# Kernel cmdline (requested defaults + documented systemd rd.luks.name format)
CMDLINE_BASE="root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rootflags=subvol=@ rw quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0"

info "Writing Limine config (v10 syntax) to ESP..."
LIMINE_CONF="$ESP_EFI_DIR/limine.conf"

cat > "$LIMINE_CONF" <<EOF
# Limine v10 configuration (UEFI)
# Config is placed alongside BOOTX64.EFI, which Limine checks first on UEFI.

timeout: 1
quiet: yes
editor_enabled: no
# interface_resolution: <width>x<height>   # omit => automatic

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
    module_path: boot():/$( [[ -f "/mnt/boot/$FALLBACK_INITRAMFS_FILE" ]] && echo "$FALLBACK_INITRAMFS_FILE" || echo "$INITRAMFS_FILE" )
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

# Optional: if limine-install exists (some setups), show it but DO NOT rely on it.
if arch-chroot /mnt bash -lc 'command -v limine-install >/dev/null 2>&1'; then
  warn "limine-install detected in chroot, but UEFI install is already done via BOOTX64.EFI copy."
fi

echo
info "ESP (/mnt/boot) contents:"
ls -lh /mnt/boot
echo
info "EFI/BOOT contents:"
ls -lh "$ESP_EFI_DIR"
echo
info "Bootloader setup completed."
