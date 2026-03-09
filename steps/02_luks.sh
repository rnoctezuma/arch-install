#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 02: LUKS2 encryption on ROOT partition
# Reads:  /tmp/arch_disk
# Writes: /tmp/arch_mapper, /tmp/arch_root_part
#
# Notes:
# - cryptsetup benchmarks PBKDF; requested pbkdf-memory is a target/max and may
#   be lowered to hit iter-time (documented by cryptsetup).
# ==============================================================================

TMP_ARCH_DISK="/tmp/arch_disk"
TMP_ARCH_MAPPER="/tmp/arch_mapper"
TMP_ARCH_ROOT_PART="/tmp/arch_root_part"

DISK=""
ROOT_PART=""
MAPPER=""
OPENED=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    set +e
    rm -f "$TMP_ARCH_MAPPER" "$TMP_ARCH_ROOT_PART" 2>/dev/null || true
    if [[ $OPENED -eq 1 && -n "${MAPPER:-}" ]]; then
      cryptsetup close "$MAPPER" >/dev/null 2>&1 || true
    fi
    warn "Step 02 failed (exit code $ec). Cleaned /tmp state."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."

require_cmd lsblk
require_cmd cryptsetup
require_cmd blkid
require_cmd sync

[[ -f "$TMP_ARCH_DISK" ]] || die "Missing $TMP_ARCH_DISK (run step 01)."
DISK="$(<"$TMP_ARCH_DISK")"
[[ -b "$DISK" ]] || die "Disk not found: $DISK"

command -v udevadm >/dev/null 2>&1 && udevadm settle || true

if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
  ROOT_PART="${DISK}p2"
else
  ROOT_PART="${DISK}2"
fi

info "Disk: $DISK"
info "Root partition: $ROOT_PART"
[[ -b "$ROOT_PART" ]] || die "Root partition not found: $ROOT_PART"

# Safety: refuse if mounted or swap
if grep -qE "^${ROOT_PART} " /proc/mounts 2>/dev/null; then
  die "Root partition appears mounted: $ROOT_PART"
fi
if grep -qE "^${ROOT_PART} " /proc/swaps 2>/dev/null; then
  die "Root partition appears used as swap: $ROOT_PART"
fi

# Mapper name: default cryptroot, but pick a free one if needed.
base="cryptroot"
MAPPER="$base"
if [[ -e "/dev/mapper/$MAPPER" ]]; then
  warn "/dev/mapper/$MAPPER exists; selecting a free mapper name."
  for i in {1..9}; do
    if [[ ! -e "/dev/mapper/${base}${i}" ]]; then
      MAPPER="${base}${i}"
      break
    fi
  done
fi
[[ ! -e "/dev/mapper/$MAPPER" ]] || die "No free mapper name cryptroot..cryptroot9"

if cryptsetup isLuks "$ROOT_PART" >/dev/null 2>&1; then
  warn "Existing LUKS header detected on $ROOT_PART."
  read -rp "Type YES to overwrite it (DESTROYS DATA): " CONFIRM_LUKS
  [[ "${CONFIRM_LUKS:-}" == "YES" ]] || die "Aborted by user."
fi

PBKDF_MEMORY_KIB="${PBKDF_MEMORY_KIB:-262144}"   # 256 MiB
ITER_TIME_MS="${ITER_TIME_MS:-2000}"            # ~2s target
PARALLEL=4
if command -v nproc >/dev/null 2>&1; then
  cores="$(nproc || echo 4)"
  [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )) && PARALLEL="$cores"
fi
(( PARALLEL > 4 )) && PARALLEL=4
(( PARALLEL < 1 )) && PARALLEL=1

echo
warn "About to encrypt: $ROOT_PART"
echo "LUKS settings:"
echo " type          : luks2"
echo " cipher        : aes-xts-plain64"
echo " key-size      : 512 (XTS => AES-256 effective)"
echo " hash          : sha512"
echo " pbkdf         : argon2id"
echo " pbkdf-memory  : ${PBKDF_MEMORY_KIB} KiB"
echo " pbkdf-parallel: ${PARALLEL}"
echo " iter-time     : ${ITER_TIME_MS} ms"
echo
read -rp "Type YES to format and encrypt (ALL DATA LOST): " CONFIRM
[[ "${CONFIRM:-}" == "YES" ]] || die "Aborted by user."

info "Creating LUKS2 container..."
cryptsetup luksFormat \
  --type luks2 \
  --label cryptroot \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  --pbkdf-memory "$PBKDF_MEMORY_KIB" \
  --pbkdf-parallel "$PARALLEL" \
  --iter-time "$ITER_TIME_MS" \
  --verify-passphrase \
  "$ROOT_PART"

sync
info "Opening as /dev/mapper/$MAPPER ..."
cryptsetup open "$ROOT_PART" "$MAPPER"
OPENED=1
sync
command -v udevadm >/dev/null 2>&1 && udevadm settle || true

printf '%s\n' "$MAPPER" > "$TMP_ARCH_MAPPER"
printf '%s\n' "$ROOT_PART" > "$TMP_ARCH_ROOT_PART"
sync

info "State written:"
echo " $TMP_ARCH_MAPPER   = $MAPPER"
echo " $TMP_ARCH_ROOT_PART= $ROOT_PART"
echo
lsblk -p -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
