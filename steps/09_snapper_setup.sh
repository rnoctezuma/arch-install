#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 09: Snapper initial setup + pacman hooks (pre/post snapshots)
# Runs inside installed system.
#
# - Uses existing /.snapshots mount created by our Btrfs layout
# - Creates config "root" manually if missing and registers it in /etc/conf.d/snapper
# - Enables snapper timeline + cleanup timers (enable only; don't --now in chroot)
# - Adds pacman hooks creating proper pre/post pairs (stores pre-number in /var)
# ==============================================================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit() {
  local ec=$?
  if (( ec != 0 )); then
    warn "Step 09 failed (exit code $ec)."
  fi
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
grep -q '^ID=arch$' /etc/os-release || die "Run inside installed Arch system."

require_cmd pacman
require_cmd systemctl
require_cmd mountpoint
require_cmd mount
require_cmd install
require_cmd sed
require_cmd awk
require_cmd grep
require_cmd chmod
require_cmd cat
require_cmd date
require_cmd mv
require_cmd rm
require_cmd mktemp

set_snapper_var() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -Eq "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

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

CONFIG="/etc/snapper/configs/root"
TEMPLATE="/etc/snapper/config-templates/default"
SNAPPER_GLOBAL="/etc/conf.d/snapper"

# Create snapper config manually because /.snapshots already exists as our own subvolume
if [[ ! -f "$CONFIG" ]]; then
  info "Creating snapper config 'root' manually for existing /.snapshots layout..."
  install -d -m 0755 /etc/snapper/configs

  if [[ -f "$TEMPLATE" ]]; then
    cat "$TEMPLATE" > "$CONFIG"
  else
    : > "$CONFIG"
  fi

  set_snapper_var SUBVOLUME '"/"' "$CONFIG"
  set_snapper_var FSTYPE '"btrfs"' "$CONFIG"
  set_snapper_var QGROUP '""' "$CONFIG"
else
  warn "Snapper config 'root' already exists."
fi

[[ -f "$CONFIG" ]] || die "Snapper config not found: $CONFIG"

info "Registering snapper config in /etc/conf.d/snapper"
if [[ -f "$SNAPPER_GLOBAL" ]]; then
  if grep -Eq '^SNAPPER_CONFIGS=' "$SNAPPER_GLOBAL"; then
    sed -Ei 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' "$SNAPPER_GLOBAL"
  else
    printf '\nSNAPPER_CONFIGS="root"\n' >> "$SNAPPER_GLOBAL"
  fi
else
  printf 'SNAPPER_CONFIGS="root"\n' > "$SNAPPER_GLOBAL"
fi

info "Configuring snapper timeline retention..."
# Keep current chosen values
set_snapper_var TIMELINE_CREATE '"yes"' "$CONFIG"
set_snapper_var TIMELINE_CLEANUP '"yes"' "$CONFIG"
set_snapper_var TIMELINE_LIMIT_HOURLY '"4"' "$CONFIG"
set_snapper_var TIMELINE_LIMIT_DAILY '"5"' "$CONFIG"
set_snapper_var TIMELINE_LIMIT_WEEKLY '"3"' "$CONFIG"
set_snapper_var TIMELINE_LIMIT_MONTHLY '"1"' "$CONFIG"
set_snapper_var NUMBER_CLEANUP '"yes"' "$CONFIG"
set_snapper_var NUMBER_LIMIT '"20"' "$CONFIG"

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
TMP="$(mktemp)"

SNAPNUM="$(snapper --no-dbus -c root create -t pre -p -d "pacman pre" -c number)"

if [[ ! "$SNAPNUM" =~ ^[0-9]+$ ]]; then
  exit 0
fi

echo "$SNAPNUM $(date +%s)" > "$TMP"
mv -f "$TMP" "$STATE"
EOF
chmod +x /usr/local/sbin/snapper-pacman-pre

cat > /usr/local/sbin/snapper-pacman-post <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE="/var/lib/snapper/pacman-pre-number"

[[ -f "$STATE" ]] || exit 0

read -r PRENUM PRETS < "$STATE" || {
  rm -f "$STATE"
  exit 0
}

if [[ ! "$PRENUM" =~ ^[0-9]+$ ]]; then
  rm -f "$STATE"
  exit 0
fi

NOW="$(date +%s)"
MAX_AGE=3600

if [[ -n "${PRETS:-}" && "$PRETS" =~ ^[0-9]+$ ]]; then
  AGE=$(( NOW - PRETS ))

  if (( AGE < 0 )); then
    rm -f "$STATE"
    exit 0
  fi

  if (( AGE > MAX_AGE )); then
    rm -f "$STATE"
    exit 0
  fi
fi

if ! snapper --no-dbus -c root list \
    | awk -v n="$PRENUM" '$1 == n && $3 == "pre" {found=1} END{exit !found}'
then
  rm -f "$STATE"
  exit 0
fi

rm -f "$STATE"

snapper --no-dbus -c root create \
  -t post \
  --pre-number "$PRENUM" \
  -p \
  -d "pacman post" \
  -c number >/dev/null || true
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