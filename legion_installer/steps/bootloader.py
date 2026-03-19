from __future__ import annotations

from pathlib import Path

from ..exceptions import InstallerError
from ..templates import find_first_existing, render_limine_conf
from .base import Step


class BootloaderStep(Step):
    name = "06_bootloader"
    description = "Install Limine and write limine.conf"

    def run(self, ctx) -> None:
        self.require_state(ctx, "mapper_name", "root_partition")
        root = Path(ctx.config.installer.target_mountpoint)
        boot = root / "boot"
        if not boot.exists():
            raise InstallerError("/boot is not mounted in target system")

        ctx.runner.run(["arch-chroot", ctx.config.installer.target_mountpoint, "pacman", "-S", "--noconfirm", "--needed", "limine"])

        efi_src = root / "usr/share/limine/BOOTX64.EFI"
        if not efi_src.exists():
            found = list((root / "usr/share").glob("**/BOOTX64.EFI"))
            if not found:
                raise InstallerError("BOOTX64.EFI not found after installing limine")
            efi_src = found[0]

        esp_dir = boot / "EFI/BOOT"
        esp_dir.mkdir(parents=True, exist_ok=True)
        (esp_dir / "BOOTX64.EFI").write_bytes(efi_src.read_bytes())

        kernel_candidates = [f"vmlinuz-{ctx.config.boot.prefer_kernel}"]
        for candidate in ("vmlinuz-linux-zen", "vmlinuz-linux-lts"):
            if candidate not in kernel_candidates:
                kernel_candidates.append(candidate)
        kernel_file = find_first_existing(boot, *kernel_candidates)
        if kernel_file is None:
            raise InstallerError("No supported kernel found in /boot")

        preset = kernel_file.removeprefix("vmlinuz-")
        initramfs_file = f"initramfs-{preset}.img"
        fallback_file = f"initramfs-{preset}-fallback.img"
        if not (boot / initramfs_file).exists():
            raise InstallerError(f"Missing /boot/{initramfs_file}")
        if not (boot / fallback_file).exists():
            fallback_file = initramfs_file

        crypt_uuid = ctx.runner.run(["blkid", "-s", "UUID", "-o", "value", ctx.state.root_partition or ""]).stdout.strip()
        if not crypt_uuid:
            raise InstallerError("Failed to detect LUKS UUID")

        extra_lts_block = ""
        if kernel_file != "vmlinuz-linux-lts" and (boot / "vmlinuz-linux-lts").exists() and (boot / "initramfs-linux-lts.img").exists():
            lts_fallback = "initramfs-linux-lts-fallback.img" if (boot / "initramfs-linux-lts-fallback.img").exists() else "initramfs-linux-lts.img"
            ucode_line = "    module_path: boot():/intel-ucode.img\n" if (boot / "intel-ucode.img").exists() else ""
            base_cmdline = (
                f"root=/dev/mapper/{ctx.state.mapper_name} "
                f"rd.luks.name={crypt_uuid}={ctx.state.mapper_name} "
                f"rd.luks.options={crypt_uuid}=discard rootflags=subvol=@ rw {ctx.config.boot.cmdline_quiet}"
            )
            fallback_cmdline = (
                f"root=/dev/mapper/{ctx.state.mapper_name} "
                f"rd.luks.name={crypt_uuid}={ctx.state.mapper_name} "
                f"rd.luks.options={crypt_uuid}=discard rootflags=subvol=@ rw {ctx.config.boot.fallback_cmdline_extra}"
            )
            extra_lts_block = (
                "/Arch Linux (linux-lts)\n"
                "    protocol: linux\n"
                "    kernel_path: boot():/vmlinuz-linux-lts\n"
                f"{ucode_line}"
                "    module_path: boot():/initramfs-linux-lts.img\n"
                f"    cmdline: {base_cmdline}\n\n"
                "/Arch Linux (linux-lts, fallback initramfs)\n"
                "    protocol: linux\n"
                "    kernel_path: boot():/vmlinuz-linux-lts\n"
                f"{ucode_line}"
                f"    module_path: boot():/{lts_fallback}\n"
                f"    cmdline: {fallback_cmdline}\n\n"
            )

        conf = render_limine_conf(
            timeout_seconds=ctx.config.boot.timeout_seconds,
            kernel_file=kernel_file,
            initramfs_file=initramfs_file,
            fallback_initramfs_file=fallback_file,
            mapper_name=ctx.state.mapper_name or "cryptroot",
            crypt_uuid=crypt_uuid,
            quiet_args=ctx.config.boot.cmdline_quiet,
            fallback_extra_args=ctx.config.boot.fallback_cmdline_extra,
            intel_ucode_present=(boot / "intel-ucode.img").exists(),
            extra_lts_block=extra_lts_block,
        )
        (esp_dir / "limine.conf").write_text(conf)
        self.info(ctx, "Limine installed and configured")
