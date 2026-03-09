#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 09: Snapper initial setup + pacman hooks (pre/post snapshots)
# Runs inside installed system.
#
# - Creates config "root" for /
# - Enables snapper timeline + cleanup timers (enable only; don't --now in chroot)
# - Adds pacman hooks creating proper pre/post pairs (stores pre-number in /var)
# ==============================================================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit(){
  local ec=$?
  [[ $ec -ne 0 ]] && warn "Step 09 failed (exit code $ec)."
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "Run inside installed system."

require_cmd pacman
require_cmd snapper || true
require_cmd btrfs || true
require_cmd systemctl
require_cmd mkdir
require_cmd chmod
require_cmd cat

info "Installing snapper..."
pacman -S --noconfirm --needed snapper

require_cmd snapper
require_cmd btrfs

# Ensure snapshots mount exists (from our Btrfs layout + fstab)
if ! mountpoint -q /.snapshots; then
  warn "/.snapshots is not a mountpoint. Attempting mount -a..."
  mount -a || true
fi
mountpoint -q /.snapshots || die "/.snapshots is not mounted. Check fstab/subvol layout."

# Create snapper config (no DBus in chroot)
if ! snapper --no-dbus list-configs 2>/dev/null | awk '{print $1}' | grep -qx root; then
  info "Creating snapper config 'root' for /"
  snapper --no-dbus -c root create-config /
else
  warn "Snapper config 'root' already exists."
fi

CONFIG="/etc/snapper/configs/root"
[[ -f "$CONFIG" ]] || die "Snapper config not found: $CONFIG"

info "Configuring snapper timeline retention..."
# Conservative defaults (tune later)
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' "$CONFIG"
sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="10"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="3"/' "$CONFIG"
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' "$CONFIG"
sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="15"/' "$CONFIG"

info "Enabling snapper timers (enable only in chroot)..."
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# ---- Pacman hooks: proper pre/post pair --------------------------------------
info "Installing pacman hooks for snapper pre/post snapshots..."

install -d -m 0755 /usr/local/sbin
install -d -m 0755 /etc/pacman.d/hooks
install -d -m 0755 /var/lib/snapper

cat > /usr/local/sbin/snapper-pacman-pre <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="/var/lib/snapper/pacman-pre-number"
SNAPNUM="$(snapper --no-dbus -c root create -t pre -p -d "pacman pre" -c number)"
echo "$SNAPNUM" > "$STATE"
EOF
chmod +x /usr/local/sbin/snapper-pacman-pre

cat > /usr/local/sbin/snapper-pacman-post <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="/var/lib/snapper/pacman-pre-number"
if [[ ! -f "$STATE" ]]; then
  exit 0
fi
PRENUM="$(<"$STATE")"
rm -f "$STATE"
snapper --no-dbus -c root create -t post --pre-number "$PRENUM" -p -d "pacman post" -c number >/dev/null
EOF
chmod +x /usr/local/sbin/snapper-pacman-post

cat > /etc/pacman.d/hooks/50-snapper-pre.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Snapper pre snapshot (before pacman transaction)
When = PreTransaction
Exec = /usr/local/sbin/snapper-pacman-pre
Depends = snapper
EOF

cat > /etc/pacman.d/hooks/50-snapper-post.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Snapper post snapshot (after successful pacman transaction)
When = PostTransaction
Exec = /usr/local/sbin/snapper-pacman-post
Depends = snapper
EOF

info "Snapper setup complete."
