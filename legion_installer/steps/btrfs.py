from __future__ import annotations

from pathlib import Path

from ..exceptions import InstallerError
from .base import Step


class BtrfsStep(Step):
    name = "03_btrfs"
    description = "Create Btrfs filesystem, subvolumes and mount layout"

    def run(self, ctx) -> None:
        self.require_state(ctx, "disk", "root_partition", "mapper_name")
        ctx.runner.require_commands("mount", "umount", "lsblk", "blkid", "pacman")

        if ctx.runner.run(["bash", "-lc", "command -v mkfs.btrfs >/dev/null 2>&1"], check=False).returncode != 0:
            ctx.runner.run(["pacman", "-S", "--noconfirm", "--needed", "btrfs-progs"])
        if ctx.runner.run(["bash", "-lc", "command -v mkfs.fat >/dev/null 2>&1"], check=False).returncode != 0:
            ctx.runner.run(["pacman", "-S", "--noconfirm", "--needed", "dosfstools"])

        ctx.runner.require_commands("mkfs.btrfs", "btrfs", "mkfs.fat")

        disk = ctx.state.disk or ""
        mapper = ctx.state.mapper_name or ""
        device = f"/dev/mapper/{mapper}"
        if not Path(device).exists():
            raise InstallerError(f"Mapper device not found: {device}")

        ctx.runner.run(["umount", "-R", ctx.config.installer.target_mountpoint], check=False)

        efi_part = ctx.runner.run_live_shell(
            f"lsblk -npo PATH,PARTLABEL {disk} | awk '$2==\"{ctx.config.disk.esp_label}\"{{print $1}}'"
        ).stdout.strip()
        if not efi_part:
            raise InstallerError("EFI partition not found")

        mount_root = ctx.config.installer.target_mountpoint
        ctx.runner.run(["mkfs.btrfs", "-f", "-L", ctx.config.btrfs.filesystem_label, device])
        ctx.runner.run(["mount", device, mount_root])
        for subvolume in ctx.config.btrfs.subvolumes:
            ctx.runner.run(["btrfs", "subvolume", "create", f"{mount_root}/{subvolume}"])
        ctx.runner.run(["umount", mount_root])

        opts = ",".join(ctx.config.btrfs.mount_options)
        ctx.runner.run(["mount", "-o", f"{opts},subvol=@", device, mount_root])
        for path in ["home", "var/log", "var/cache", ".snapshots", "boot"]:
            Path(mount_root, path).mkdir(parents=True, exist_ok=True)
        Path(mount_root, ".snapshots").chmod(0o750)

        mapping = {
            "@home": "home",
            "@log": "var/log",
            "@cache": "var/cache",
            "@snapshots": ".snapshots",
        }
        for subvol, rel_path in mapping.items():
            ctx.runner.run(["mount", "-o", f"{opts},subvol={subvol}", device, f"{mount_root}/{rel_path}"])

        ctx.runner.run(["mkfs.fat", "-F32", "-n", ctx.config.disk.esp_label, efi_part])
        blkid = ctx.runner.run(["blkid", efi_part]).stdout
        if 'TYPE="vfat"' not in blkid:
            raise InstallerError(f"EFI partition is not FAT32: {efi_part}")
        ctx.runner.run(["mount", efi_part, f"{mount_root}/boot"])
        self.info(ctx, "Btrfs layout and ESP mounted")
