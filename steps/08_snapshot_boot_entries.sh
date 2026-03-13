#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 08: Snapshot-aware Limine boot entry generator (Limine v10)
# Runs inside installed system (chroot during install, and later at runtime).
#
# Idempotency:
# - Rewrites only the block between:
#   # --- SNAPSHOT AUTO START ---
#   # --- SNAPSHOT AUTO END ---
#
# Installer state:
# - During install-time, state files may exist in /root/arch-install-state
# - After reboot, runtime auto-detection is used instead
# ==============================================================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

DRYRUN=0
VERBOSE=0
KEEP_N=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRYRUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --keep)
      [[ $# -ge 2 ]] || die "--keep requires a numeric argument"
      KEEP_N="${2:-}"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

logv() {
  if [[ $VERBOSE -eq 1 ]]; then
    info "$*"
  fi
  return 0
}

cleanup_on_exit() {
  local ec=$?

  if [[ -n "${BLOCK:-}" && -f "${BLOCK:-}" ]]; then
    rm -f "$BLOCK" >/dev/null 2>&1 || true
  fi
  if [[ -n "${NEWCONF:-}" && -f "${NEWCONF:-}" ]]; then
    rm -f "$NEWCONF" >/dev/null 2>&1 || true
  fi

  if (( ec != 0 )); then
    warn "Step 08 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "Run inside installed system."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI mode required."

require_cmd sed
require_cmd awk
require_cmd find
require_cmd sort
require_cmd mountpoint
require_cmd grep
require_cmd sync
require_cmd mktemp
require_cmd cat

mountpoint -q /boot || die "/boot is not mounted (ESP missing)."

CONF="/boot/EFI/BOOT/limine.conf"
[[ -f "$CONF" ]] || die "limine.conf not found: $CONF"

# ---- Kernel + initramfs detection --------------------------------------------
pick_kernel() {
  local f
  for f in vmlinuz-linux-zen vmlinuz-linux-lts; do
    [[ -f "/boot/$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

KERNEL_FILE="$(pick_kernel)" || die "No supported kernel found in /boot."
PRESET="${KERNEL_FILE#vmlinuz-}"
INITRAMFS_FILE="initramfs-${PRESET}.img"
[[ -f "/boot/$INITRAMFS_FILE" ]] || die "Missing /boot/$INITRAMFS_FILE"

UCODE_LINE=""
if [[ -f /boot/intel-ucode.img ]]; then
  UCODE_LINE="    module_path: boot():/intel-ucode.img"
fi

# ---- Mapper + LUKS UUID detection --------------------------------------------
STATE_DIR="/root/arch-install-state"
MAPPER=""
CRYPT_UUID=""

if [[ -f "${STATE_DIR}/arch_mapper" ]]; then
  MAPPER="$(< "${STATE_DIR}/arch_mapper")"
fi

if [[ -z "$MAPPER" ]]; then
  require_cmd findmnt
  src="$(findmnt -no SOURCE / || true)"
  [[ "$src" == /dev/mapper/* ]] || die "Cannot detect mapper from root mount SOURCE=$src"
  MAPPER="${src#/dev/mapper/}"
fi

if [[ -f "${STATE_DIR}/arch_root_part" ]]; then
  require_cmd blkid
  ROOT_PART="$(< "${STATE_DIR}/arch_root_part")"
  [[ -b "$ROOT_PART" ]] || die "Root partition from ${STATE_DIR} not found: $ROOT_PART"
  CRYPT_UUID="$(blkid -s UUID -o value "$ROOT_PART" || true)"
fi

if [[ -z "$CRYPT_UUID" ]]; then
  require_cmd cryptsetup
  require_cmd blkid
  dev="$(cryptsetup status "$MAPPER" 2>/dev/null | awk -F': ' '/device:/ {print $2; exit}' || true)"
  [[ -n "${dev:-}" && -b "${dev:-}" ]] || die "Failed to detect underlying LUKS block device for mapper: $MAPPER"
  CRYPT_UUID="$(blkid -s UUID -o value "$dev" || true)"
fi

[[ -n "$CRYPT_UUID" ]] || die "Failed to detect LUKS UUID."

CMDLINE_BASE_PREFIX="root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rd.luks.options=${CRYPT_UUID}=discard rw quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0"

logv "Kernel: $KERNEL_FILE"
logv "Initramfs: $INITRAMFS_FILE"
logv "Mapper: $MAPPER"
logv "LUKS UUID: $CRYPT_UUID"

# ---- Snapper snapshot discovery ----------------------------------------------
SNAP_BASE=""
if [[ -d "/.snapshots" ]]; then
  SNAP_BASE="/.snapshots"
elif [[ -d "/@snapshots" ]]; then
  SNAP_BASE="/@snapshots"
else
  info "No snapshots directory found (/.snapshots or /@snapshots). Nothing to do."
  exit 0
fi

mapfile -t SNAP_IDS < <(
  find "$SNAP_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E '^[0-9]+$' \
    | sort -rV
)

SNAP_OK=()
for id in "${SNAP_IDS[@]}"; do
  [[ -d "${SNAP_BASE}/${id}/snapshot" ]] || continue
  SNAP_OK+=("$id")
done

START="# --- SNAPSHOT AUTO START ---"
END="# --- SNAPSHOT AUTO END ---"

if [[ ${#SNAP_OK[@]} -eq 0 ]]; then
  info "No valid Snapper snapshots found under $SNAP_BASE."

  NEWCONF="$(mktemp)"
  awk -v start="$START" -v end="$END" '
    BEGIN{inside=0}
    $0==start {print; inside=1; next}
    inside && $0==end {print; inside=0; next}
    inside {next}
    {print}
  ' "$CONF" > "$NEWCONF"

  if [[ $DRYRUN -eq 1 ]]; then
    info "Dry-run: would clear snapshot entries in $CONF."
    exit 0
  fi

  cat "$NEWCONF" > "$CONF"
  sync
  info "Snapshot entries cleared (no valid snapshots found)."
  exit 0
fi

if [[ "$KEEP_N" =~ ^[0-9]+$ ]] && (( KEEP_N > 0 )) && (( ${#SNAP_OK[@]} > KEEP_N )); then
  SNAP_OK=( "${SNAP_OK[@]:0:KEEP_N}" )
fi

BLOCK="$(mktemp)"
NEWCONF="$(mktemp)"

{
  echo "# Auto-generated snapshot entries (newest-first)"
  echo "# Generated by steps/08_snapshot_boot_entries.sh"
  echo
  for id in "${SNAP_OK[@]}"; do
    echo "/Arch Linux (snapshot #${id})"
    echo "    protocol: linux"
    echo "    kernel_path: boot():/${KERNEL_FILE}"
    [[ -n "$UCODE_LINE" ]] && echo "$UCODE_LINE"
    echo "    module_path: boot():/${INITRAMFS_FILE}"
    echo "    cmdline: ${CMDLINE_BASE_PREFIX} rootflags=subvol=@snapshots/${id}/snapshot"
    echo
  done
} > "$BLOCK"

if grep -qF "$START" "$CONF" && grep -qF "$END" "$CONF"; then
  awk -v start="$START" -v end="$END" -v block="$BLOCK" '
    BEGIN{inside=0}
    $0==start {print; system("cat " block); inside=1; next}
    inside && $0==end {print; inside=0; next}
    inside {next}
    {print}
  ' "$CONF" > "$NEWCONF"
else
  cat "$CONF" > "$NEWCONF"
  {
    echo
    echo "$START"
    cat "$BLOCK"
    echo "$END"
  } >> "$NEWCONF"
fi

if [[ $DRYRUN -eq 1 ]]; then
  info "Dry-run: would update $CONF with ${#SNAP_OK[@]} snapshot entries."
  exit 0
fi

cat "$NEWCONF" > "$CONF"
sync
info "Snapshot entries updated: ${#SNAP_OK[@]} entries written."