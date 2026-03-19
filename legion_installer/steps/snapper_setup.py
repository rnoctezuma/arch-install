from __future__ import annotations

from pathlib import Path

from .base import Step, write_executable


class SnapperSetupStep(Step):
    name = "09_snapper_setup"
    description = "Install Snapper and pacman hooks"

    def run(self, ctx) -> None:
        root = Path(ctx.config.installer.target_mountpoint)
        etc = root / "etc"
        runtime_dir = ctx.config.installer.target_runtime_dir

        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "pacman", "-S", "--noconfirm", "--needed", "snapper"])
        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "mount", "-a"], check=False)

        config_dir = etc / "snapper/configs"
        config_dir.mkdir(parents=True, exist_ok=True)
        config_file = config_dir / "root"
        if not config_file.exists():
            template = root / "etc/snapper/config-templates/default"
            config_file.write_text(template.read_text() if template.exists() else "")

        text = config_file.read_text()
        replacements = {
            "SUBVOLUME": '"/"',
            "FSTYPE": '"btrfs"',
            "QGROUP": '""',
            "TIMELINE_CREATE": '"yes"',
            "TIMELINE_CLEANUP": '"yes"',
            "TIMELINE_LIMIT_HOURLY": f'"{ctx.config.snapper.timeline_hourly}"',
            "TIMELINE_LIMIT_DAILY": f'"{ctx.config.snapper.timeline_daily}"',
            "TIMELINE_LIMIT_WEEKLY": f'"{ctx.config.snapper.timeline_weekly}"',
            "TIMELINE_LIMIT_MONTHLY": f'"{ctx.config.snapper.timeline_monthly}"',
            "NUMBER_CLEANUP": '"yes"',
            "NUMBER_LIMIT": f'"{ctx.config.snapper.number_limit}"',
        }
        lines = text.splitlines()
        for key, value in replacements.items():
            for index, line in enumerate(lines):
                if line.startswith(f"{key}="):
                    lines[index] = f"{key}={value}"
                    break
            else:
                lines.append(f"{key}={value}")
        config_file.write_text("\n".join(lines) + "\n")

        confd = etc / "conf.d/snapper"
        existing = confd.read_text() if confd.exists() else ""
        if "SNAPPER_CONFIGS=" in existing:
            lines = ["SNAPPER_CONFIGS=\"root\"" if line.startswith("SNAPPER_CONFIGS=") else line for line in existing.splitlines()]
            confd.write_text("\n".join(lines) + "\n")
        else:
            confd.write_text(existing + ("\n" if existing and not existing.endswith("\n") else "") + 'SNAPPER_CONFIGS="root"\n')

        write_executable(
            root / "usr/local/sbin/snapper-pacman-pre",
            f"#!/usr/bin/env python3\nimport sys\nsys.path.insert(0, '{runtime_dir}')\nfrom legion_installer.runtime import pacman_pre_snapshot\nraise SystemExit(pacman_pre_snapshot())\n",
        )
        write_executable(
            root / "usr/local/sbin/snapper-pacman-post",
            f"#!/usr/bin/env python3\nimport sys\nsys.path.insert(0, '{runtime_dir}')\nfrom legion_installer.runtime import pacman_post_snapshot\nraise SystemExit(pacman_post_snapshot())\n",
        )

        hooks_dir = etc / "pacman.d/hooks"
        hooks_dir.mkdir(parents=True, exist_ok=True)
        (hooks_dir / "50-snapper-pre.hook").write_text(
            "[Trigger]\n"
            "Operation = Install\n"
            "Operation = Upgrade\n"
            "Operation = Remove\n"
            "Type = Package\n"
            "Target = *\n\n"
            "[Action]\n"
            "Description = Snapper pre snapshot (before pacman transaction)\n"
            "When = PreTransaction\n"
            "Exec = /usr/local/sbin/snapper-pacman-pre\n"
            "Depends = snapper\n"
        )
        (hooks_dir / "50-snapper-post.hook").write_text(
            "[Trigger]\n"
            "Operation = Install\n"
            "Operation = Upgrade\n"
            "Operation = Remove\n"
            "Type = Package\n"
            "Target = *\n\n"
            "[Action]\n"
            "Description = Snapper post snapshot (after successful pacman transaction)\n"
            "When = PostTransaction\n"
            "Exec = /usr/local/sbin/snapper-pacman-post\n"
            "Depends = snapper\n"
        )

        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "systemctl", "enable", "snapper-timeline.timer"])
        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "systemctl", "enable", "snapper-cleanup.timer"])
        self.info(ctx, "Snapper configured and pacman hooks installed")
