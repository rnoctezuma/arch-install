#!/usr/bin/env bash
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"

SNAPPER_CMD_DIR="/etc/snapper/commands"
mkdir -p "$SNAPPER_CMD_DIR"

HOOK_FILE="$SNAPPER_CMD_DIR/99-limine-refresh"

info "Installing Snapper → Limine auto-refresh hook..."

cat > "$HOOK_FILE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/limine-snapshot-refresh.log"
LOCK="/run/limine-snapshot-refresh.lock"

{
echo "[$(date)] Snapper post-snapshot hook triggered"

# Prevent concurrent refresh
exec 9>"$LOCK" || exit 0
flock -n 9 || {
    echo "Another refresh running, exiting."
    exit 0
}

if [[ -x /usr/local/sbin/limine-snapshot-refresh ]]; then
    /usr/local/sbin/limine-snapshot-refresh
    echo "Limine snapshot refresh completed."
else
    echo "Refresh script missing."
fi

} >> "$LOG" 2>&1
EOF

chmod +x "$HOOK_FILE"

info "Installing limine refresh executable..."

mkdir -p /usr/local/sbin

cat > /usr/local/sbin/limine-snapshot-refresh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Lightweight wrapper to call main generator

if [[ -x /root/08_snapshot_boot_entries.sh ]]; then
    /root/08_snapshot_boot_entries.sh
elif [[ -x /usr/local/sbin/08_snapshot_boot_entries.sh ]]; then
    /usr/local/sbin/08_snapshot_boot_entries.sh
else
    exit 0
fi
EOF

chmod +x /usr/local/sbin/limine-snapshot-refresh

info "Snapper auto-refresh hook installed."
