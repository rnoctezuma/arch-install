#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"
mountpoint -q /boot || die "/boot not mounted"
[[ -d /.snapshots ]] || { info "No snapshots directory"; exit 0; }

[[ -f /tmp/arch_mapper ]] || die "Missing /tmp/arch_mapper"
[[ -f /tmp/arch_root_part ]] || die "Missing /tmp/arch_root_part"

MAPPER="$(< /tmp/arch_mapper)"
ROOT_PART="$(< /tmp/arch_root_part)"
CRYPT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"

KERNEL_FILE="$(ls /boot/vmlinuz-* | head -n1 | xargs -n1 basename)"
PRESET="${KERNEL_FILE#vmlinuz-}"
INITRAMFS_FILE="initramfs-${PRESET}.img"

CONF="/boot/EFI/BOOT/limine.conf"

echo "" >> "$CONF"
echo "# --- Auto-generated snapshot entries ---" >> "$CONF"

for SNAP in /.snapshots/*; do
    [[ -d "$SNAP/snapshot" ]] || continue

    ID="$(basename "$SNAP")"

    cat >> "$CONF" <<EOF

/Arch Linux Snapshot (${ID})
    protocol: linux
    kernel_path: boot():/${KERNEL_FILE}
    module_path: boot():/${INITRAMFS_FILE}
    cmdline: root=/dev/mapper/${MAPPER} rd.luks.name=${CRYPT_UUID}=${MAPPER} rootflags=subvol=.snapshots/${ID}/snapshot rw
EOF

done

info "Snapshot boot entries generated."
