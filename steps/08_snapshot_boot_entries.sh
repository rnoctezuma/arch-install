#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 08: Snapshot-aware Limine boot entry generator (production)
# Runs inside arch-chroot
# Idempotent, safe, newest-first ordering
# ==============================================================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

cleanup_on_exit(){
    local ec=$?
    if [[ $ec -ne 0 ]]; then
        warn "Step 08 failed (exit code $ec)."
    fi
}
trap cleanup_on_exit EXIT

# ------------------------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ -f /etc/arch-release ]] || die "Not inside installed system"

mountpoint -q /boot || die "/boot not mounted"

CONF="/boot/EFI/BOOT/limine.conf"
[[ -f "$CONF" ]] || die "limine.conf not found at $CONF"

[[ -f /tmp/arch_mapper ]] || die "Missing /tmp/arch_mapper"
[[ -f /tmp/arch_root_part ]] || die "Missing /tmp/arch_root_part"

MAPPER="$(< /tmp/arch_mapper)"
ROOT_PART="$(< /tmp/arch_root_part)"

[[ -b "$ROOT_PART" ]] || die "Root partition not found"

CRYPT_UUID="$(blkid -s UUID -o value "$ROOT_PART" || true)"
[[ -n "$CRYPT_UUID" ]] || die "Failed to detect LUKS UUID"

# ------------------------------------------------------------------------------
# Detect kernel + initramfs
# ------------------------------------------------------------------------------

pick_kernel() {
    for f in \
        vmlinuz-linux-cachyos-nvidia-open \
        vmlinuz-linux-cachyos-nvidia \
        vmlinuz-linux-cachyos \
        vmlinuz-linux
    do
        [[ -f "/boot/$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

KERNEL_FILE="$(pick_kernel)" || die "No supported kernel found in /boot"

PRESET="${KERNEL_FILE#vmlinuz-}"
INITRAMFS_FILE="initramfs-${PRESET}.img"

[[ -f "/boot/$INITRAMFS_FILE" ]] || die "Missing /boot/$INITRAMFS_FILE"

# Optional microcode
UCODE_LINE=""
if [[ -f /boot/intel-ucode.img ]]; then
    UCODE_LINE="    module_path: boot():/intel-ucode.img"
fi

# ------------------------------------------------------------------------------
# Snapshot detection
# ------------------------------------------------------------------------------

SNAPSHOT_DIR="/.snapshots"

if [[ ! -d "$SNAPSHOT_DIR" ]]; then
    info "No /.snapshots directory found. Nothing to generate."
    exit 0
fi

# Remove previous auto block safely
sed -i '/# --- SNAPSHOT AUTO START ---/,/# --- SNAPSHOT AUTO END ---/d' "$CONF"

# Collect valid snapshots (Snapper layout)
mapfile -t SNAP_LIST < <(
    find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d \
    -exec test -d "{}/snapshot" \; \
    -print 2>/dev/null \
    | sort -rV
)

if [[ ${#SNAP_LIST[@]} -eq 0 ]]; then
    info "No valid snapshots detected."
    exit 0
fi

# ------------------------------------------------------------------------------
# Generate snapshot entries
# ------------------------------------------------------------------------------

{
echo ""
echo "# --- SNAPSHOT AUTO START ---"
echo "# Generated automatically. Do not edit manually."
echo ""

for SNAP in "${SNAP_LIST[@]}"; do
    ID="$(basename "$SNAP")"

cat <<EOF
/Arch Linux Snapshot (${ID})
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
${UCODE_LINE}
    module_path: boot():/${INITRAMFS_FILE}
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rootflags=subvol=.snapshots/${ID}/snapshot rw quiet
EOF

done

echo "# --- SNAPSHOT AUTO END ---"
} >> "$CONF"

sync

# ------------------------------------------------------------------------------
# Debug output
# ------------------------------------------------------------------------------

echo
info "Snapshot entries regenerated successfully."
info "Total snapshots added: ${#SNAP_LIST[@]}"
echo
