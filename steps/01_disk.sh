#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Arch Installer - Step 01: Disk Selection & Partitioning (UEFI-only)
#
# Target install design:
#   - UEFI-only boot (required by ESP + Limine approach)
#   - GPT disk label
#   - 2 partitions:
#       1) EFI System Partition (ESP): 1MiB -> 2049MiB (FAT32, esp flag)
#       2) ROOT partition            : 2049MiB -> 100% (LUKS2 -> Btrfs later)
#
# Output contract:
#   - Writes the selected *disk* path (e.g., /dev/nvme0n1) to:
#       /tmp/arch_disk
#   - This file is required by steps/02_luks.sh
#
# Notes:
#   - This script is intentionally interactive (read -rp prompts).
#   - It refuses to run if not booted in UEFI mode.
#   - It warns if the disk already has partitions or is mounted/in use.
# ==============================================================================

TMP_ARCH_DISK="/tmp/arch_disk"
DISK=""

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found in PATH: $1"
}

cleanup_on_exit() {
  # Runs on any exit; only performs cleanup if we are exiting with an error.
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    set +e

    # Prevent later steps from using stale disk selection after failures.
    rm -f "$TMP_ARCH_DISK" 2>/dev/null || true

    # Best-effort: unmount any still-mounted partitions from the selected disk.
    # (Only relevant if the user confirmed proceeding on an in-use disk.)
    if [[ -n "${DISK:-}" && -b "${DISK:-}" ]]; then
      mapfile -t _parts < <(lsblk -nrpo NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="part"{print $1}')
      for p in "${_parts[@]}"; do
        while read -r mp; do
          [[ -n "${mp:-}" ]] || continue
          umount "$mp" 2>/dev/null || true
        done < <(awk -v dev="$p" '$1==dev{print $2}' /proc/mounts 2>/dev/null)
      done

      # Best-effort: rescan partition table state.
      sync 2>/dev/null || true
      partprobe "$DISK" 2>/dev/null || true
      sync 2>/dev/null || true
    fi

    warn "Step 01 failed (exit code $ec). Temporary state cleaned (removed $TMP_ARCH_DISK)."
  fi
}
trap cleanup_on_exit EXIT

# --- Preconditions ------------------------------------------------------------

# Partition manipulation requires root.
[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root."

# UEFI-only: required for an ESP + Limine configuration.
if [[ ! -d /sys/firmware/efi/efivars ]]; then
  die "UEFI variables not found at /sys/firmware/efi/efivars.
Boot the Arch ISO in UEFI mode (disable CSM/Legacy boot)."
fi

# Required tools (assumed available on Arch ISO; fail clearly if missing).
require_cmd lsblk
require_cmd parted
require_cmd partprobe

# Clear stale selection from previous runs.
rm -f "$TMP_ARCH_DISK" 2>/dev/null || true

# --- UI: disk selection -------------------------------------------------------

echo "===================================="
echo "Arch Installer - Disk Partitioning"
echo "===================================="
echo

info "Available disks (TYPE=disk):"
# Use explicit columns (better for scripts; avoids default-output changes).
# Filter by TYPE at end of line to avoid issues with spaces in MODEL.
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN,ROTA,TYPE | grep -E ' disk$' || true
echo

read -rp "Enter disk to use (example: /dev/nvme0n1): " DISK_RAW
DISK="$(echo "${DISK_RAW:-}" | tr -d '[:space:]')"

[[ -n "$DISK" ]] || die "No disk entered."
[[ "$DISK" == /dev/* ]] || die "Disk must be a /dev path (example: /dev/nvme0n1)."
[[ -b "$DISK" ]] || die "Disk not found or not a block device: $DISK"

# Ensure the user selected a whole disk, not a partition.
DISK_TYPE="$(lsblk -dnro TYPE "$DISK" 2>/dev/null || true)"
[[ "$DISK_TYPE" == "disk" ]] || die "$DISK is not a whole-disk device (TYPE=$DISK_TYPE).
Use a disk like /dev/nvme0n1, not a partition like /dev/nvme0n1p1."

info "Selected disk: $DISK"
echo

# Safety: refuse to destroy the live ISO USB if detectable.
LIVE_SRC="$(awk '$2=="/run/archiso/bootmnt"{print $1; exit}' /proc/mounts 2>/dev/null || true)"
if [[ -n "${LIVE_SRC:-}" && -b "${LIVE_SRC:-}" ]]; then
  LIVE_PARENT="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null || true)"
  if [[ -n "${LIVE_PARENT:-}" && "/dev/$LIVE_PARENT" == "$DISK" ]]; then
    die "Selected disk ($DISK) appears to be the Arch ISO live media (mounted at /run/archiso/bootmnt).
Refusing to continue to avoid destroying the installer USB."
  fi
fi

# --- In-use checks ------------------------------------------------------------

mapfile -t PARTS < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}')

HAS_PARTS=0
(( ${#PARTS[@]} > 0 )) && HAS_PARTS=1

MOUNTED_ENTRIES=()
SWAP_DEVS=()

for p in "${PARTS[@]}"; do
  # Mounted partitions (source column in /proc/mounts is /dev/XYZ)
  if grep -qE "^${p} " /proc/mounts 2>/dev/null; then
    while read -r mp; do
      [[ -n "${mp:-}" ]] && MOUNTED_ENTRIES+=("${p}:${mp}")
    done < <(awk -v dev="$p" '$1==dev{print $2}' /proc/mounts 2>/dev/null)
  fi

  # Active swap devices
  if grep -qE "^${p} " /proc/swaps 2>/dev/null; then
    SWAP_DEVS+=("$p")
  fi
done

IN_USE=0
(( HAS_PARTS == 1 )) && IN_USE=1
(( ${#MOUNTED_ENTRIES[@]} > 0 )) && IN_USE=1
(( ${#SWAP_DEVS[@]} > 0 )) && IN_USE=1

if (( IN_USE == 1 )); then
  warn "Disk appears to already have partitions and/or be in use."

  if (( HAS_PARTS == 1 )); then
    warn "Existing partitions detected:"
    # Explicit columns; show PARTLABEL and mountpoints for operator visibility.
    lsblk -p -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,LABEL,MOUNTPOINTS "$DISK" || true
    echo
  fi

  if (( ${#MOUNTED_ENTRIES[@]} > 0 )); then
    warn "Mounted partitions detected:"
    for entry in "${MOUNTED_ENTRIES[@]}"; do
      echo "  - $entry"
    done
    echo
  fi

  if (( ${#SWAP_DEVS[@]} > 0 )); then
    warn "Active swap detected on:"
    for dev in "${SWAP_DEVS[@]}"; do
      echo "  - $dev"
    done
    echo
  fi
fi

# --- Final operator confirmation ---------------------------------------------

echo "WARNING: This will ERASE ALL DATA on $DISK."
echo "Planned layout:"
echo "  1) EFI System Partition (FAT32, ESP flag) : 1MiB  -> 2049MiB (~2GiB)"
echo "  2) ROOT partition (for LUKS2 + Btrfs later): 2049MiB -> 100%"
echo

read -rp "Type YES to continue (anything else cancels): " CONFIRM
if [[ "${CONFIRM:-}" != "YES" ]]; then
  echo "Cancelled. No changes were made."
  exit 0
fi

if (( IN_USE == 1 )); then
  echo
  read -rp "Disk is in use/already partitioned. Type YES again to proceed anyway: " CONFIRM2
  if [[ "${CONFIRM2:-}" != "YES" ]]; then
    echo "Cancelled. No changes were made."
    exit 0
  fi
fi

# If mounted partitions are present, attempt to unmount them now (post-confirmation).
if (( ${#MOUNTED_ENTRIES[@]} > 0 )); then
  warn "Attempting to unmount partitions on $DISK..."
  mapfile -t MOUNTPOINTS_ONLY < <(
    printf '%s\n' "${MOUNTED_ENTRIES[@]}" \
      | awk -F: '{print $2}' \
      | awk '{print length($0) "\t" $0}' \
      | sort -rn \
      | cut -f2-
  )

  for mp in "${MOUNTPOINTS_ONLY[@]}"; do
    info "umount $mp"
    umount "$mp" || die "Failed to unmount $mp. Unmount manually and re-run."
  done
fi

# If active swap is on the disk, attempt swapoff (post-confirmation).
if (( ${#SWAP_DEVS[@]} > 0 )); then
  if command -v swapoff >/dev/null 2>&1; then
    warn "Attempting to disable swap on $DISK..."
    for dev in "${SWAP_DEVS[@]}"; do
      info "swapoff $dev"
      swapoff "$dev" || die "Failed to swapoff $dev. Disable swap manually and re-run."
    done
  else
    die "Active swap detected on $DISK, but swapoff is not available. Disable swap manually and re-run."
  fi
fi

# Give udev a chance to settle before we modify partition tables.
if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

# --- Partitioning -------------------------------------------------------------

info "Creating GPT partition table..."
# -s: script mode (no prompts)
# -a optimal: align partitions for best performance based on disk topology
parted -s -a optimal "$DISK" mklabel gpt

info "Creating EFI partition (ESP) ..."
parted -s -a optimal "$DISK" mkpart EFI fat32 1MiB 2049MiB
parted -s "$DISK" set 1 esp on

info "Creating ROOT partition ..."
parted -s -a optimal "$DISK" mkpart ROOT 2049MiB 100%

info "Informing kernel of partition table changes..."
partprobe "$DISK"
sync

if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

# --- Result + contract output -------------------------------------------------

echo
info "Partitioning complete. Final layout:"
lsblk -p -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,MOUNTPOINTS "$DISK"
echo

# Write contract file for next step.
printf '%s\n' "$DISK" > "$TMP_ARCH_DISK"
sync
info "Wrote selected disk to $TMP_ARCH_DISK (required by step 02)."
