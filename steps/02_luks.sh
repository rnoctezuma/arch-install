#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 02: LUKS2 encryption on ROOT partition
#
# Contract:
#   - reads disk path from /tmp/arch_disk (written by step 01)
#   - detects ROOT partition:
#       nvme*/mmcblk*  -> ${DISK}p2
#       others         -> ${DISK}2
#   - creates LUKS2 container on ROOT partition
#   - opens it as /dev/mapper/<mapper>
#   - writes:
#       /tmp/arch_mapper     (mapper name only, e.g. cryptroot)
#       /tmp/arch_root_part  (root partition path, e.g. /dev/nvme0n1p2)
#
# Crypto choices:
#   - LUKS2 + Argon2id
#   - pbkdf-memory default is 256 MiB (262144 KiB) to avoid OOM/slow unlock
#     while still being strong. cryptsetup notes PBKDF alloc uses real RAM. (see
#     cryptsetup-luksFormat(8))
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

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

[[ ${EUID:-0} -eq 0 ]] || die "This script must be run as root."

require_cmd lsblk
require_cmd cryptsetup
require_cmd blkid
require_cmd sync

if [[ ! -f "$TMP_ARCH_DISK" ]]; then
  die "Disk info not found at $TMP_ARCH_DISK. Run step 01 first."
fi

DISK="$(<"$TMP_ARCH_DISK")"
[[ -n "$DISK" ]] || die "$TMP_ARCH_DISK is empty."
[[ -b "$DISK" ]] || die "Disk not found or not a block device: $DISK"

if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

# Detect root partition (must match step01 layout)
if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
  ROOT_PART="${DISK}p2"
else
  ROOT_PART="${DISK}2"
fi

info "Disk: $DISK"
info "Using root partition: $ROOT_PART"

[[ -b "$ROOT_PART" ]] || die "Root partition not found: $ROOT_PART (check step 01)."

# Refuse to work if the partition is mounted or used as swap (very unsafe).
if grep -qE "^${ROOT_PART} " /proc/mounts 2>/dev/null; then
  die "Root partition appears mounted. Unmount it before continuing: $ROOT_PART"
fi
if grep -qE "^${ROOT_PART} " /proc/swaps 2>/dev/null; then
  die "Root partition appears used as swap. Disable swap before continuing: $ROOT_PART"
fi

# Choose a unique mapper name (default 'cryptroot' to keep your later scripts simple)
base="cryptroot"
MAPPER="$base"
if [[ -e "/dev/mapper/$MAPPER" ]]; then
  warn "/dev/mapper/$MAPPER already exists; choosing a unique mapper name."
  for i in {1..9}; do
    if [[ ! -e "/dev/mapper/${base}${i}" ]]; then
      MAPPER="${base}${i}"
      break
    fi
  done
fi
[[ -e "/dev/mapper/$MAPPER" ]] && die "Could not find free mapper name (cryptroot..cryptroot9)."

# Detect existing LUKS header
if cryptsetup isLuks "$ROOT_PART" >/dev/null 2>&1; then
  warn "Existing LUKS header detected on $ROOT_PART."
  warn "Continuing will DESTROY the current LUKS container."
  read -rp "Type YES to continue anyway: " CONFIRM_LUKS
  [[ "${CONFIRM_LUKS:-}" == "YES" ]] || die "Aborted by user."
fi

# PBKDF tuning
PBKDF_MEMORY_KIB="${PBKDF_MEMORY_KIB:-262144}"   # 256 MiB
ITER_TIME_MS="${ITER_TIME_MS:-2000}"             # target ~2s on this machine
PARALLEL=4
if command -v nproc >/dev/null 2>&1; then
  cores="$(nproc || echo 4)"
  if [[ "$cores" =~ ^[0-9]+$ ]] && (( cores > 0 )); then
    PARALLEL="$cores"
  fi
fi
(( PARALLEL > 4 )) && PARALLEL=4
(( PARALLEL < 1 )) && PARALLEL=1

echo
warn "About to encrypt: $ROOT_PART"
echo "LUKS settings:"
echo "  type:            luks2"
echo "  cipher:          aes-xts-plain64"
echo "  key-size:        512"
echo "  hash:            sha512"
echo "  pbkdf:           argon2id"
echo "  pbkdf-memory:    ${PBKDF_MEMORY_KIB} KiB (default 256 MiB)"
echo "  pbkdf-parallel:  ${PARALLEL}"
echo "  iter-time:       ${ITER_TIME_MS} ms (benchmark target)"
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

info "Opening encrypted container as /dev/mapper/$MAPPER ..."
cryptsetup open "$ROOT_PART" "$MAPPER"
OPENED=1

sync
if command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

printf '%s\n' "$MAPPER" > "$TMP_ARCH_MAPPER"
printf '%s\n' "$ROOT_PART" > "$TMP_ARCH_ROOT_PART"
sync

info "State written:"
echo "  $TMP_ARCH_MAPPER = $MAPPER"
echo "  $TMP_ARCH_ROOT_PART = $ROOT_PART"
echo

lsblk -p -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
