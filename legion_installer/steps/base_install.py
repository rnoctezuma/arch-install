from __future__ import annotations

from pathlib import Path

from ..templates import enable_pacman_option, render_mirrorlist
from .base import Step


class BaseInstallStep(Step):
    name = "04_base_install"
    description = "Install base Arch system with pacstrap"

    def run(self, ctx) -> None:
        mount_root = Path(ctx.config.installer.target_mountpoint)
        if not mount_root.exists():
            raise RuntimeError(f"Missing target mountpoint: {mount_root}")

        net_ok = False
        if ctx.runner.run(["ping", "-c", "1", "-W", "2", "1.1.1.1"], check=False).returncode == 0:
            net_ok = True
        if not net_ok and ctx.runner.run(["curl", "-fsSLI", "--max-time", "5", "https://archlinux.org"], check=False).returncode == 0:
            net_ok = True
        if not net_ok:
            raise RuntimeError("Network appears offline.")

        ctx.runner.run(["pacman", "-Sy", "--noconfirm", "archlinux-keyring"])
        Path("/etc/pacman.d/mirrorlist").write_text(render_mirrorlist(ctx.config.packages.mirrorlist))
        ctx.runner.run(["pacman", "-Syy", "--noconfirm"])
        ctx.runner.run(["pacstrap", "-K", ctx.config.installer.target_mountpoint, *ctx.config.packages.base])

        pacman_conf = mount_root / "etc/pacman.conf"
        text = pacman_conf.read_text()
        text = enable_pacman_option(text, "Color")
        text = enable_pacman_option(text, "ParallelDownloads")
        text = enable_pacman_option(text, "VerbosePkgLists")
        if "ILoveCandy" not in text:
            text = text.replace("Color\n", "Color\nILoveCandy\n")
        pacman_conf.write_text(text)

        fstab_path = mount_root / "etc/fstab"
        generated = ctx.runner.run(["genfstab", "-U", ctx.config.installer.target_mountpoint]).stdout
        existing = fstab_path.read_text() if fstab_path.exists() else ""
        merged_lines: list[str] = []
        seen: set[str] = set()
        for line in (existing + generated).splitlines():
            if line not in seen:
                seen.add(line)
                merged_lines.append(line)
        fstab_path.write_text("\n".join(merged_lines).rstrip() + "\n")

        if Path("/etc/resolv.conf").exists():
            target_resolv = mount_root / "etc/resolv.conf"
            if target_resolv.exists() or target_resolv.is_symlink():
                target_resolv.unlink()
            target_resolv.write_text(Path("/etc/resolv.conf").read_text())

        ctx.sync_state_to_target()
        ctx.install_runtime_tree()
        self.info(ctx, "Base system installed and runtime tree copied")
