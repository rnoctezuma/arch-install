#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Step 10: Snapper plugin -> refresh Limine snapshot boot entries automatically
#
# Snapper plugin mechanism:
# - plugins live in /usr/lib/snapper/plugins
# - called on actions like create-snapshot-post (see snapper(8))
#
# We install:
# 1) /usr/local/sbin/08_snapshot_boot_entries.sh  (persistent generator copy)
# 2) /usr/local/sbin/limine-snapshot-refresh      (safe wrapper)
# 3) /usr/lib/snapper/plugins/90-limine-refresh   (plugin hook)
# ==============================================================================

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }
warn(){ echo "WARNING: $*" >&2; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_on_exit(){
  local ec=$?
  [[ $ec -ne 0 ]] && warn "Step 10 failed (exit code $ec)."
}
trap cleanup_on_exit EXIT

[[ ${EUID:-0} -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "Run inside installed system."

require_cmd install
require_cmd chmod
require_cmd cat
require_cmd flock || true

# Persist the generator script (it was copied into /root by install.sh)
if [[ -f /root/08_snapshot_boot_entries.sh ]]; then
  install -d -m 0755 /usr/local/sbin
  install -m 0755 /root/08_snapshot_boot_entries.sh /usr/local/sbin/08_snapshot_boot_entries.sh
  info "Installed persistent generator: /usr/local/sbin/08_snapshot_boot_entries.sh"
else
  warn "/root/08_snapshot_boot_entries.sh not found. Generator will not be installed persistently."
fi

# Wrapper (never fails hard)
cat > /usr/local/sbin/limine-snapshot-refresh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/limine-snapshot-refresh.log"
LOCK="/run/limine-snapshot-refresh.lock"

{
  echo "[$(date --iso-8601=seconds)] refresh requested"
  if ! mountpoint -q /boot; then
    echo "boot not mounted, skipping"
    exit 0
  fi

  # prevent concurrent refresh
  exec 9>"$LOCK" || exit 0
  flock -n 9 || { echo "already running, exiting"; exit 0; }

  if [[ -x /usr/local/sbin/08_snapshot_boot_entries.sh ]]; then
    /usr/local/sbin/08_snapshot_boot_entries.sh || { echo "generator failed, ignored"; exit 0; }
  else
    echo "generator missing, skipping"
  fi
} >>"$LOG" 2>&1

exit 0
EOF
chmod +x /usr/local/sbin/limine-snapshot-refresh

# Snapper plugin
install -d -m 0755 /usr/lib/snapper/plugins
cat > /usr/lib/snapper/plugins/90-limine-refresh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Arguments:
#   $1 = action (e.g. create-snapshot-post)
#   others depend on action (see snapper(8))
action="${1:-}"

case "$action" in
  create-snapshot-post|rollback-post)
    ;;
  *)
    exit 0
    ;;
esac

# Never break snapper: swallow errors.
if [[ -x /usr/local/sbin/limine-snapshot-refresh ]]; then
  /usr/local/sbin/limine-snapshot-refresh || true
fi

exit 0
EOF
chmod +x /usr/lib/snapper/plugins/90-limine-refresh

info "Snapper -> Limine auto-refresh hook installed."
