from __future__ import annotations

import time
from pathlib import Path

from ..exceptions import InstallerError
from .base import Step, ask_required, ask_yes_no


class DiskPartitionStep(Step):
    name = "01_disk"
    description = "Select disk and create GPT + EFI + ROOT partitions"

    def _detect_disk_type(self, ctx, disk: str) -> str:
        return ctx.runner.run(["lsblk", "-dnro", "TYPE", disk]).stdout.strip()

    def _find_live_iso_parent(self, ctx) -> str | None:
        mounts = Path("/proc/mounts").read_text().splitlines()
        source = None
        for line in mounts:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "/run/archiso/bootmnt":
                source = parts[0]
                break
        if not source:
            return None
        result = ctx.runner.run(["lsblk", "-no", "PKNAME", source], check=False)
        parent = result.stdout.strip()
        return f"/dev/{parent}" if parent else None

    def _list_partitions(self, ctx, disk: str) -> list[str]:
        output = ctx.runner.run(["lsblk", "-nrpo", "NAME,TYPE", disk]).stdout.splitlines()
        parts: list[str] = []
        for line in output:
            fields = line.split()
            if len(fields) >= 2 and fields[1] == "part":
                parts.append(fields[0])
        return parts

    def _mounted_targets(self, device: str) -> list[str]:
        targets: list[str] = []
        for line in Path("/proc/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == device:
                targets.append(parts[1])
        return targets

    def _is_swap(self, device: str) -> bool:
        for line in Path("/proc/swaps").read_text().splitlines()[1:]:
            parts = line.split()
            if parts and parts[0] == device:
                return True
        return False

    def _choose_disk(self, ctx) -> str:
        if ctx.config.disk.device:
            return ctx.config.disk.device

        listing = ctx.runner.run(["lsblk", "-d", "-p", "-n", "-o", "NAME,SIZE,MODEL,TRAN,ROTA", "-e", "7"]).stdout
        print("Available disks:\n")
        print(listing)
        return ask_required("Enter disk to use")

    def run(self, ctx) -> None:
        ctx.runner.require_root()
        ctx.runner.require_uefi()
        ctx.runner.require_commands(
            "lsblk",
            "parted",
            "partprobe",
            "wipefs",
            "cryptsetup",
            "dmsetup",
            "umount",
            "swapoff",
            "findmnt",
        )

        disk = self._choose_disk(ctx).strip()
        if not disk:
            raise InstallerError("No disk entered")
        if not disk.startswith("/dev/"):
            raise InstallerError(f"Disk must be a /dev path: {disk}")
        disk_path = Path(disk)
        if not disk_path.exists() or not disk_path.is_block_device():
            raise InstallerError(f"Disk not found or not a block device: {disk}")
        if self._detect_disk_type(ctx, disk) != "disk":
            raise InstallerError(f"Selected device is not TYPE=disk: {disk}")

        live_parent = self._find_live_iso_parent(ctx)
        if live_parent and live_parent == disk:
            raise InstallerError(f"Selected disk {disk} appears to be the live ISO media.")

        partitions = self._list_partitions(ctx, disk)
        mounted = {part: self._mounted_targets(part) for part in partitions}
        swaps = [part for part in partitions if self._is_swap(part)]
        in_use = bool(partitions or any(mounted.values()) or swaps)

        if in_use:
            self.warn(ctx, f"Disk {disk} already has partitions or active mounts.")
            print(ctx.runner.run(["lsblk", "-p", "-o", "NAME,SIZE,TYPE,PARTLABEL,FSTYPE,LABEL,MOUNTPOINTS", disk]).stdout)

        print(f"WARNING: This will ERASE ALL DATA on {disk}.")
        print("Planned layout:")
        print(f" 1) ESP  : {ctx.config.disk.esp_start} -> {ctx.config.disk.esp_end}")
        print(f" 2) ROOT : {ctx.config.disk.esp_end} -> 100%")

        if not ctx.config.disk.force and not ask_yes_no("Proceed with destructive partitioning?", default=False):
            raise InstallerError("Aborted by user.")

        if in_use and not ctx.config.disk.force and not ask_yes_no("Disk is in use. Proceed anyway?", default=False):
            raise InstallerError("Aborted by user.")

        for targets in mounted.values():
            for target in sorted(targets, key=len, reverse=True):
                ctx.runner.run(["umount", target], check=False)

        for swap in swaps:
            ctx.runner.run(["swapoff", swap], check=False)

        ctx.runner.run(["udevadm", "settle"], check=False)
        ctx.runner.run_live_shell(
            f"for dev in $(lsblk -rno NAME,TYPE {disk} | awk '$2==\"crypt\"{{print $1}}'); do cryptsetup close $dev 2>/dev/null || true; done",
            check=False,
        )
        ctx.runner.run(["cryptsetup", "close", "cryptroot"], check=False)
        ctx.runner.run_live_shell(
            f"while read -r mp; do umount -R \"$mp\" 2>/dev/null || true; done < <(findmnt -rn -S {disk} -o TARGET 2>/dev/null || true)",
            check=False,
        )
        ctx.runner.run(["swapoff", "-a"], check=False)
        ctx.runner.run(["dmsetup", "remove_all", "--force"], check=False)
        ctx.runner.run(["udevadm", "settle"], check=False)
        time.sleep(1)

        ctx.runner.run(["wipefs", "-af", disk])
        ctx.runner.run(["parted", "-s", "-a", "optimal", disk, "mklabel", "gpt"])
        ctx.runner.run([
            "parted",
            "-s",
            "-a",
            "optimal",
            disk,
            "mkpart",
            ctx.config.disk.esp_label,
            "fat32",
            ctx.config.disk.esp_start,
            ctx.config.disk.esp_end,
        ])
        ctx.runner.run(["parted", "-s", disk, "set", "1", "esp", "on"])
        ctx.runner.run(["parted", "-s", disk, "name", "1", ctx.config.disk.esp_label])
        ctx.runner.run([
            "parted",
            "-s",
            "-a",
            "optimal",
            disk,
            "mkpart",
            ctx.config.disk.root_label,
            ctx.config.disk.esp_end,
            "100%",
        ])
        ctx.runner.run(["partprobe", disk])
        ctx.runner.run(["sync"], check=False)
        ctx.runner.run(["udevadm", "settle"], check=False)

        root_part = ctx.runner.run_live_shell(
            f"lsblk -rno PATH,PARTLABEL {disk} | awk '$2==\"{ctx.config.disk.root_label}\"{{print $1}}'"
        ).stdout.strip()
        if not root_part:
            raise InstallerError("Failed to detect ROOT partition by PARTLABEL")

        ctx.state.disk = disk
        ctx.state.root_partition = root_part
        ctx.save_state()
        self.info(ctx, f"Selected disk: {disk}; root partition: {root_part}")
