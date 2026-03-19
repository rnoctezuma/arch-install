from __future__ import annotations

from .base import Step


class SnapshotEntriesStep(Step):
    name = "08_snapshot_boot_entries"
    description = "Generate snapshot-aware Limine entries"

    def run(self, ctx) -> None:
        runtime_dir = ctx.config.installer.target_runtime_dir
        state_dir = ctx.config.installer.target_state_dir
        keep = str(ctx.config.snapper.plugin_keep_snapshots)
        ctx.runner.run(
            [
                "arch-chroot",
                ctx.config.installer.target_mountpoint,
                "/usr/bin/env",
                f"PYTHONPATH={runtime_dir}",
                "python3",
                "-m",
                "legion_installer.runtime",
                "refresh-limine-snapshots",
                "--state-dir",
                state_dir,
                "--keep",
                keep,
            ]
        )
        self.info(ctx, "Snapshot boot entries refreshed")
