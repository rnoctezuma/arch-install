#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"
mountpoint -q / || die "Root not mounted"

info "Installing snapper..."
pacman -S --noconfirm --needed snapper

# Ensure .snapshots subvolume exists
if ! btrfs subvolume show /.snapshots >/dev/null 2>&1; then
    info "Creating .snapshots subvolume..."
    btrfs subvolume create /.snapshots
fi

if ! snapper -c root list >/dev/null 2>&1; then
    info "Creating snapper config for root (@)"
    snapper -c root create-config /
fi

info "Configuring snapper cleanup policy..."

CONFIG="/etc/snapper/configs/root"

sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' "$CONFIG"
sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="10"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/' "$CONFIG"
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="3"/' "$CONFIG"

sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' "$CONFIG"
sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="15"/' "$CONFIG"

info "Enabling snapper timers..."
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# ---- Pacman hook ----

info "Creating pacman pre/post snapshot hooks..."

mkdir -p /etc/pacman.d/hooks

cat > /etc/pacman.d/hooks/50-snapper-pre.hook <<EOF
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Creating snapper pre-transaction snapshot...
When = PreTransaction
Exec = /usr/bin/snapper create --type pre --print-number --description "pacman pre"
EOF

cat > /etc/pacman.d/hooks/50-snapper-post.hook <<EOF
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Creating snapper post-transaction snapshot...
When = PostTransaction
Exec = /usr/bin/snapper create --type post --description "pacman post"
EOF

info "Snapper setup complete."
