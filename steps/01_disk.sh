#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 01: Disk Selection & Partitioning (UEFI-only)
# Layout:
#   1) ESP  : 1MiB -> 2049MiB (FAT32 later, ESP flag)
#   2) ROOT : 2049MiB -> 100%  (LUKS2 -> Btrfs later)
#
# Output contract:
#   writes selected disk (e.g. /dev/nvme0n1) to /tmp/arch_disk
# ==============================================================================

TMP_ARCH_DISK="/tmp/arch_disk"
TMP_ARCH_ROOT_PART="/tmp/arch_root_part"
DISK=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"; }

cleanup_on_exit() {
  local ec=$?
  if (( ec != 0 )); then
    set +e
    rm -f "$TMP_ARCH_DISK" "$TMP_ARCH_ROOT_PART" 2>/dev/null || true
    if [[ -n "${DISK:-}" && -b "${DISK:-}" ]]; then
      sync 2>/dev/null || true
      partprobe "$DISK" 2>/dev/null || true
      sync 2>/dev/null || true
      warn "Step 01 failed (exit code $ec). Cleaned temporary state."
    fi
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI mode required (/sys/firmware/efi/efivars missing)."

require_cmd lsblk
require_cmd parted
require_cmd partprobe
require_cmd awk
require_cmd grep
require_cmd tr
require_cmd sync

rm -f "$TMP_ARCH_DISK" 2>/dev/null || true

echo "===================================="
echo "Arch Installer - Disk Partitioning"
echo "===================================="
echo

info "Available disks (TYPE=disk):"

lsblk -d -p -n \
  -o NAME,SIZE,MODEL,TRAN,ROTA \
  -e 7

echo

read -rp "Enter disk to use (example: /dev/nvme0n1): " DISK_RAW
DISK="$(echo "${DISK_RAW:-}" | tr -d '[:space:]')"

[[ -n "$DISK" ]] || die "No disk entered."
[[ "$DISK" == /dev/* ]] || die "Disk must be a /dev path."
[[ -b "$DISK" ]] || die "Disk not found or not a block device: $DISK"

DISK_TYPE="$(lsblk -dnro TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] || die "Selected device is not TYPE=disk: $DISK (TYPE=$DISK_TYPE)"

# Avoid nuking the live ISO if it is mounted at /run/archiso/bootmnt
LIVE_SRC="$(awk '$2=="/run/archiso/bootmnt"{print $1; exit}' /proc/mounts 2>/dev/null || true)"
if [[ -n "${LIVE_SRC:-}" && -b "${LIVE_SRC:-}" ]]; then
  LIVE_PARENT="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null || true)"
  if [[ -n "${LIVE_PARENT:-}" && "/dev/$LIVE_PARENT" == "$DISK" ]]; then
    die "Selected disk ($DISK) seems to be the live ISO media. Refusing."
  fi
fi

# Detect partitions + mounts + swap usage
mapfile -t PARTS < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}' || true)
MOUNTED=()
SWAPS=()
for p in "${PARTS[@]}"; do
  if grep -qE "^${p} " /proc/mounts 2>/dev/null; then
    while read -r mp; do
      [[ -n "${mp:-}" ]] && MOUNTED+=("${p}:${mp}")
    done < <(awk -v dev="$p" '$1==dev{print $2}' /proc/mounts)
  fi
  if grep -qE "^${p} " /proc/swaps 2>/dev/null; then
    SWAPS+=("$p")
  fi
done

IN_USE=0
(( ${#PARTS[@]} > 0 )) && IN_USE=1
(( ${#MOUNTED[@]} > 0 )) && IN_USE=1
(( ${#SWAPS[@]} > 0 )) && IN_USE=1

if (( IN_USE == 1 )); then
  warn "Disk already has partitions and/or is in use."
  lsblk -p -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,LABEL,MOUNTPOINTS "$DISK" || true
  echo
fi

echo "WARNING: This will ERASE ALL DATA on $DISK."
echo "Planned layout:"
echo " 1) ESP  : 1MiB -> 2049MiB (~2GiB)"
echo " 2) ROOT : 2049MiB -> 100%"
echo

read -rp "Type YES to continue (anything else cancels): " CONFIRM
if [[ "${CONFIRM:-}" != "YES" ]]; then
  echo "Cancelled. No changes were made."
  exit 0
fi

if (( IN_USE == 1 )); then
  read -rp "Disk is in use. Type YES again to proceed anyway: " CONFIRM2
  if [[ "${CONFIRM2:-}" != "YES" ]]; then
    echo "Cancelled. No changes were made."
    exit 0
  fi
fi

# Best-effort unmount after user confirms
if (( ${#MOUNTED[@]} > 0 )); then
  warn "Unmounting mounted partitions on $DISK..."
  # Unmount deeper mountpoints first
  mapfile -t MPS < <(printf '%s\n' "${MOUNTED[@]}" | awk -F: '{print $2}' | awk '{print length($0) "\t" $0}' | sort -rn | cut -f2-)
  for mp in "${MPS[@]}"; do
    info "umount $mp"
    umount "$mp" || die "Failed to unmount $mp"
  done
fi

if (( ${#SWAPS[@]} > 0 )); then
  require_cmd swapoff
  warn "Disabling swap on $DISK..."
  for dev in "${SWAPS[@]}"; do
    info "swapoff $dev"
    swapoff "$dev" || die "Failed to swapoff $dev"
  done
fi

command -v udevadm >/dev/null 2>&1 && udevadm settle || true

info "Creating GPT partition table..."
wipefs -af "$DISK"
parted -s -a optimal "$DISK" mklabel gpt

info "Creating EFI partition (ESP)..."
parted -s -a optimal "$DISK" mkpart EFI fat32 1MiB 2049MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" name 1 EFI

info "Creating ROOT partition..."
parted -s -a optimal "$DISK" mkpart ROOT 2049MiB 100%

info "Informing kernel of partition table changes..."
partprobe "$DISK"
sync
command -v udevadm >/dev/null 2>&1 && udevadm settle || true

# Determine ROOT partition via PARTLABEL (deterministic)
ROOT_PART="$(lsblk -npo NAME,PARTLABEL "$DISK" | awk '$2=="ROOT"{print $1}')"

[[ -n "$ROOT_PART" ]] || die "Failed to detect ROOT partition by PARTLABEL."
[[ -b "$ROOT_PART" ]] || die "Detected ROOT partition is not a block device: $ROOT_PART"

printf '%s\n' "$ROOT_PART" > "$TMP_ARCH_ROOT_PART"
sync
info "ROOT partition saved to $TMP_ARCH_ROOT_PART ($ROOT_PART)"

echo
info "Final layout:"
lsblk -p -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,MOUNTPOINTS "$DISK"

printf '%s\n' "$DISK" > "$TMP_ARCH_DISK"
sync
info "Wrote selected disk to $TMP_ARCH_DISK"
