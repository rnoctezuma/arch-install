#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 01: Disk Selection & Partitioning (UEFI-only)
# Layout:
#   1) ESP  : 1MiB -> 2049MiB
#   2) ROOT : 2049MiB -> 100%
# Writes:
#   /tmp/arch_disk
#   /tmp/arch_root_part
# ==============================================================================

TMP_ARCH_DISK="/tmp/arch_disk"
TMP_ARCH_ROOT_PART="/tmp/arch_root_part"
DISK=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  ec=$?
  if (( ec != 0 )); then
    set +e
    rm -f "$TMP_ARCH_DISK" "$TMP_ARCH_ROOT_PART" 2>/dev/null || true
    [[ -n "${DISK:-}" && -b "${DISK:-}" ]] && partprobe "$DISK" 2>/dev/null || true
    warn "Step 01 failed (exit $ec)"
  fi
}
trap cleanup_on_exit EXIT

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI mode required."

require_cmd lsblk
require_cmd parted
require_cmd partprobe
require_cmd wipefs
require_cmd awk
require_cmd grep
require_cmd sync

rm -f "$TMP_ARCH_DISK" "$TMP_ARCH_ROOT_PART" 2>/dev/null || true

echo "===================================="
echo "Arch Installer - Disk Partitioning"
echo "===================================="
echo

info "Available disks:"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN,ROTA -e 7
echo

read -rp "Enter disk (example: /dev/nvme0n1): " DISK_RAW
DISK="$(echo "${DISK_RAW:-}" | tr -d '[:space:]')"

[[ -n "$DISK" ]] || die "No disk entered."
[[ "$DISK" == /dev/* ]] || die "Disk must start with /dev/"
[[ -b "$DISK" ]] || die "Not a block device: $DISK"

DISK_TYPE="$(lsblk -dnro TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] || die "Selected device is not TYPE=disk"

# ------------------------------------------------------------------------------
# Live ISO protection (strict-safe)
# ------------------------------------------------------------------------------

if command -v findmnt >/dev/null 2>&1; then
  set +e
  LIVE_SRC="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)"
  rc=$?
  set -e

  if (( rc == 0 )) && [[ -n "$LIVE_SRC" ]] && [[ -b "$LIVE_SRC" ]]; then

    if [[ "$LIVE_SRC" == /dev/loop* ]] && command -v losetup >/dev/null 2>&1; then
      set +e
      BACKING="$(losetup -no BACK-FILE "$LIVE_SRC" 2>/dev/null)"
      set -e
      [[ -n "$BACKING" ]] && LIVE_SRC="$BACKING"
    fi

    set +e
    PARENT="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null)"
    set -e

    if [[ -n "$PARENT" ]]; then
      LIVE_DISK="/dev/$PARENT"
    else
      LIVE_DISK="$LIVE_SRC"
    fi

    if [[ "$LIVE_DISK" == "$DISK" ]]; then
      die "Refusing to operate on live ISO disk: $DISK"
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Detect partitions (strict-safe, no pipelines)
# ------------------------------------------------------------------------------

PARTS=()
set +e
LSBLK_RAW="$(lsblk -nrpo NAME,TYPE "$DISK" 2>/dev/null)"
set -e

while read -r name type; do
  [[ "$type" == "part" ]] && PARTS+=("$name")
done <<< "$LSBLK_RAW"

MOUNTED=()
SWAPS=()

for p in "${PARTS[@]}"; do
  if grep -qE "^${p} " /proc/mounts 2>/dev/null; then
    while read -r dev mp _; do
      [[ "$dev" == "$p" ]] && MOUNTED+=("$mp")
    done < /proc/mounts
  fi
  if grep -qE "^${p} " /proc/swaps 2>/dev/null; then
    SWAPS+=("$p")
  fi
done

if (( ${#PARTS[@]} > 0 )); then
  warn "Disk has existing partitions."
  lsblk -p -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK" || true
fi

echo
echo "WARNING: This will ERASE ALL DATA on $DISK"
echo "Layout:"
echo " 1) ESP  : 1MiB -> 2049MiB"
echo " 2) ROOT : 2049MiB -> 100%"
echo

read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 0; }

# ------------------------------------------------------------------------------
# Unmount if needed
# ------------------------------------------------------------------------------

for mp in "${MOUNTED[@]}"; do
  info "Unmounting $mp"
  umount "$mp" || die "Failed to unmount $mp"
done

for sw in "${SWAPS[@]}"; do
  info "swapoff $sw"
  swapoff "$sw" || die "Failed to swapoff $sw"
done

sync
partprobe "$DISK" || true

# ------------------------------------------------------------------------------
# Partitioning
# ------------------------------------------------------------------------------

info "Wiping signatures..."
wipefs -af "$DISK"

info "Creating GPT..."
parted -s -a optimal "$DISK" mklabel gpt

info "Creating EFI..."
parted -s -a optimal "$DISK" mkpart EFI fat32 1MiB 2049MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" name 1 EFI

info "Creating ROOT..."
parted -s -a optimal "$DISK" mkpart ROOT 2049MiB 100%

partprobe "$DISK"
sync

# ------------------------------------------------------------------------------
# Detect ROOT partition safely
# ------------------------------------------------------------------------------

ROOT_PART=""
set +e
LSBLK_LABELS="$(lsblk -npo NAME,PARTLABEL "$DISK" 2>/dev/null)"
set -e

while read -r name label; do
  [[ "$label" == "ROOT" ]] && ROOT_PART="$name"
done <<< "$LSBLK_LABELS"

[[ -n "$ROOT_PART" ]] || die "ROOT partition not found."

printf '%s\n' "$DISK" > "$TMP_ARCH_DISK"
printf '%s\n' "$ROOT_PART" > "$TMP_ARCH_ROOT_PART"

sync

echo
info "Final layout:"
lsblk -p -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,MOUNTPOINTS "$DISK"

info "Disk written to $TMP_ARCH_DISK"
info "Root partition written to $TMP_ARCH_ROOT_PART"