from __future__ import annotations

from pathlib import Path

from ..templates import ensure_multilib_enabled, set_mkinitcpio_var
from .base import Step


class SystemConfigStep(Step):
    name = "05_system_config"
    description = "Configure locale, users, mkinitcpio and essential packages"

    def _set_password(self, ctx, username: str, password: str | None) -> None:
        if password:
            ctx.runner.run(
                ["arch-chroot", ctx.config.installer.target_mountpoint, "chpasswd"],
                input_text=f"{username}:{password}\n",
            )
        else:
            ctx.runner.run(
                ["arch-chroot", ctx.config.installer.target_mountpoint, "passwd", username],
                capture_output=False,
            )

    def run(self, ctx) -> None:
        root = Path(ctx.config.installer.target_mountpoint)
        etc = root / "etc"

        localtime = etc / "localtime"
        if localtime.exists() or localtime.is_symlink():
            localtime.unlink()
        localtime.symlink_to(Path("/usr/share/zoneinfo") / ctx.config.system.timezone)
        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "hwclock", "--systohc"])

        locale_gen = etc / "locale.gen"
        locale_text = locale_gen.read_text().replace(
            f"#{ctx.config.system.locale} UTF-8", f"{ctx.config.system.locale} UTF-8"
        )
        locale_gen.write_text(locale_text)
        (etc / "locale.conf").write_text(f"LANG={ctx.config.system.locale}\n")
        (etc / "vconsole.conf").write_text(f"KEYMAP={ctx.config.system.keymap}\n")
        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "locale-gen"])

        (etc / "hostname").write_text(f"{ctx.config.system.hostname}\n")
        (etc / "hosts").write_text(
            "127.0.0.1 localhost\n"
            "::1       localhost\n"
            f"127.0.1.1 {ctx.config.system.hostname}.localdomain {ctx.config.system.hostname}\n"
        )

        self._set_password(ctx, "root", ctx.credentials.root_password)
        if ctx.runner.run(
            ["arch-chroot", ctx.config.installer.target_mountpoint, "id", "-u", ctx.config.system.username],
            check=False,
        ).returncode != 0:
            ctx.runner.run(
                [
                    "arch-chroot",
                    ctx.config.installer.target_mountpoint,
                    "useradd",
                    "-m",
                    "-G",
                    "wheel",
                    "-s",
                    ctx.config.system.shell,
                    ctx.config.system.username,
                ]
            )
        self._set_password(ctx, ctx.config.system.username, ctx.credentials.user_password)

        sudoers_dir = etc / "sudoers.d"
        sudoers_dir.mkdir(parents=True, exist_ok=True)
        wheel_file = sudoers_dir / "10-wheel"
        wheel_file.write_text("%wheel ALL=(ALL:ALL) ALL\n")
        wheel_file.chmod(0o440)

        pacman_conf = etc / "pacman.conf"
        pacman_text = pacman_conf.read_text()
        if ctx.config.system.enable_multilib:
            pacman_text = ensure_multilib_enabled(pacman_text)
        pacman_conf.write_text(pacman_text)

        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "pacman", "-Syy", "--noconfirm"])
        ctx.runner.run(
            [
                "arch-chroot",
                ctx.config.installer.target_mountpoint,
                "pacman",
                "-S",
                "--noconfirm",
                "--needed",
                *ctx.config.packages.essential,
            ]
        )

        mkinitcpio_conf = etc / "mkinitcpio.conf"
        mk_text = mkinitcpio_conf.read_text()
        mk_text = set_mkinitcpio_var(mk_text, "MODULES", "(btrfs nvme nvidia nvidia_modeset nvidia_uvm nvidia_drm)")
        mk_text = set_mkinitcpio_var(
            mk_text,
            "HOOKS",
            "(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)",
        )
        mkinitcpio_conf.write_text(mk_text)

        preset_dir = etc / "mkinitcpio.d"
        for preset in preset_dir.glob("*.preset"):
            text = preset.read_text().replace("PRESETS=('default')", "PRESETS=('default' 'fallback')")
            preset.write_text(text)

        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "mkinitcpio", "-P"], capture_output=False)
        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "systemctl", "enable", "NetworkManager"])
        self.info(ctx, "System configuration completed")
