from __future__ import annotations

from pathlib import Path

from .base import Step, write_executable


class SnapperHookStep(Step):
    name = "10_snapper_limine_hook"
    description = "Install Snapper plugin that refreshes Limine snapshot entries"

    def run(self, ctx) -> None:
        root = Path(ctx.config.installer.target_mountpoint)
        runtime_dir = ctx.config.installer.target_runtime_dir
        state_dir = ctx.config.installer.target_state_dir
        keep = ctx.config.snapper.plugin_keep_snapshots

        write_executable(
            root / "usr/local/sbin/08_snapshot_boot_entries.sh",
            (
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"PYTHONPATH='{runtime_dir}' exec python3 -m legion_installer.runtime refresh-limine-snapshots --state-dir '{state_dir}' --keep {keep}\n"
            ),
        )

        write_executable(
            root / "usr/local/sbin/limine-snapshot-refresh",
            (
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "LOG='/var/log/limine-snapshot-refresh.log'\n"
                "LOCK='/run/limine-snapshot-refresh.lock'\n"
                "{\n"
                "  echo \"[$(date --iso-8601=seconds)] refresh requested\"\n"
                "  if ! mountpoint -q /boot; then\n"
                "    echo 'boot not mounted, skipping'\n"
                "    exit 0\n"
                "  fi\n\n"
                "  exec 9>\"$LOCK\" || exit 0\n"
                "  flock -n 9 || { echo 'already running, exiting'; exit 0; }\n\n"
                "  if [[ -x /usr/local/sbin/08_snapshot_boot_entries.sh ]]; then\n"
                "    /usr/local/sbin/08_snapshot_boot_entries.sh || { echo 'generator failed, ignored'; exit 0; }\n"
                "  else\n"
                "    echo 'generator missing, skipping'\n"
                "  fi\n"
                "} >>\"$LOG\" 2>&1\n\n"
                "exit 0\n"
            ),
        )

        plugin_dir = root / "usr/lib/snapper/plugins"
        plugin_dir.mkdir(parents=True, exist_ok=True)
        write_executable(
            plugin_dir / "90-limine-refresh",
            (
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n"
                'action="${1:-}"\n\n'
                "case \"$action\" in\n"
                "  create-snapshot-post|rollback-post|delete-snapshot-post|cleanup-post) ;;\n"
                "  *) exit 0 ;;\n"
                "esac\n\n"
                "if [[ -x /usr/local/sbin/limine-snapshot-refresh ]]; then\n"
                "  /usr/local/sbin/limine-snapshot-refresh || true\n"
                "fi\n\n"
                "exit 0\n"
            ),
        )
        self.info(ctx, "Snapper -> Limine refresh hook installed")
