from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import subprocess
import time
from pathlib import Path

from .templates import find_first_existing, render_snapshot_block, replace_snapshot_block

LOG = logging.getLogger("legion_installer.runtime")
DEFAULT_QUIET_ARGS = "quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0 nvidia-drm.modeset=1"


def _configure_logging() -> None:
    if LOG.handlers:
        return
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def _run(command: list[str], *, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    LOG.debug("RUN %s", " ".join(command))
    completed = subprocess.run(command, check=False, text=True, capture_output=True, input=input_text)
    if check and completed.returncode != 0:
        raise RuntimeError(f"Command failed ({completed.returncode}): {' '.join(command)}\n{completed.stderr.strip()}")
    return completed


def _state_dir(path: str | None) -> Path:
    return Path(path or "/root/arch-install-state")


def _mountpoint_active(path: str) -> bool:
    target = os.path.abspath(path)
    with open("/proc/mounts", "r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == target:
                return True
    return False


def _detect_mapper(state_dir: Path) -> str:
    mapper_file = state_dir / "arch_mapper"
    if mapper_file.exists():
        return mapper_file.read_text().strip()
    completed = _run(["findmnt", "-no", "SOURCE", "/"])
    source = completed.stdout.strip()
    if source.startswith("/dev/mapper/"):
        return source.removeprefix("/dev/mapper/")
    raise RuntimeError(f"Cannot detect mapper from root source: {source}")


def _detect_crypt_uuid(state_dir: Path, mapper_name: str) -> str:
    root_part_file = state_dir / "arch_root_part"
    if root_part_file.exists():
        root_part = root_part_file.read_text().strip()
        completed = _run(["blkid", "-s", "UUID", "-o", "value", root_part])
        return completed.stdout.strip()

    completed = _run(["cryptsetup", "status", mapper_name])
    lines = completed.stdout.splitlines() + completed.stderr.splitlines()
    for line in lines:
        if line.strip().startswith("device:"):
            device = line.split(":", 1)[1].strip()
            uuid = _run(["blkid", "-s", "UUID", "-o", "value", device]).stdout.strip()
            if uuid:
                return uuid
    raise RuntimeError("Failed to detect LUKS UUID")


def _discover_snapshot_base() -> Path | None:
    for candidate in (Path("/.snapshots"), Path("/@snapshots")):
        if candidate.is_dir():
            return candidate
    return None


def _discover_snapshot_ids(snapshot_dir: Path, keep: int) -> list[str]:
    ids: list[str] = []
    for entry in snapshot_dir.iterdir():
        if entry.is_dir() and entry.name.isdigit() and (entry / "snapshot").is_dir():
            ids.append(entry.name)
    ids.sort(key=lambda value: int(value), reverse=True)
    return ids[:keep] if keep > 0 else ids


def _load_quiet_args(state_dir: Path) -> str:
    config_path = state_dir / "install-config.json"
    if not config_path.exists():
        return DEFAULT_QUIET_ARGS
    try:
        data = json.loads(config_path.read_text())
        quiet_args = data.get("boot", {}).get("cmdline_quiet")
        if isinstance(quiet_args, str) and quiet_args.strip():
            return quiet_args.strip()
    except Exception:
        pass
    return DEFAULT_QUIET_ARGS


def refresh_limine_snapshot_entries(state_dir_arg: str | None = None, keep: int = 0) -> int:
    _configure_logging()
    if not _mountpoint_active("/boot"):
        LOG.info("/boot is not mounted; skipping snapshot refresh")
        return 0

    state_dir = _state_dir(state_dir_arg)
    lock_path = Path("/run/limine-snapshot-refresh.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    with lock_path.open("w") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            LOG.info("snapshot refresh already running; skipping")
            return 0

        conf = Path("/boot/EFI/BOOT/limine.conf")
        if not conf.exists():
            raise RuntimeError(f"limine.conf not found: {conf}")

        boot_dir = Path("/boot")
        kernel_file = find_first_existing(boot_dir, "vmlinuz-linux-zen", "vmlinuz-linux-lts")
        if kernel_file is None:
            raise RuntimeError("No supported kernel found in /boot")

        preset = kernel_file.removeprefix("vmlinuz-")
        initramfs_file = f"initramfs-{preset}.img"
        if not (boot_dir / initramfs_file).exists():
            raise RuntimeError(f"Missing {boot_dir / initramfs_file}")

        mapper_name = _detect_mapper(state_dir)
        crypt_uuid = _detect_crypt_uuid(state_dir, mapper_name)
        quiet_args = _load_quiet_args(state_dir)
        snapshot_base = _discover_snapshot_base()
        snapshot_ids = _discover_snapshot_ids(snapshot_base, keep) if snapshot_base else []

        block = render_snapshot_block(
            kernel_file=kernel_file,
            initramfs_file=initramfs_file,
            mapper_name=mapper_name,
            crypt_uuid=crypt_uuid,
            snapshot_ids=snapshot_ids,
            quiet_args=quiet_args,
            intel_ucode_present=(boot_dir / "intel-ucode.img").exists(),
        )
        conf.write_text(replace_snapshot_block(conf.read_text(), block))
        LOG.info("Updated limine snapshot entries: %s entries", len(snapshot_ids))
    return 0


def pacman_pre_snapshot() -> int:
    _configure_logging()
    state_file = Path("/var/lib/snapper/pacman-pre-number")
    state_file.parent.mkdir(parents=True, exist_ok=True)
    snapnum = _run(["snapper", "--no-dbus", "-c", "root", "create", "-t", "pre", "-p", "-d", "pacman pre", "-c", "number"]).stdout.strip()
    if snapnum.isdigit():
        state_file.write_text(f"{snapnum} {int(time.time())}\n")
    return 0


def pacman_post_snapshot() -> int:
    _configure_logging()
    state_file = Path("/var/lib/snapper/pacman-pre-number")
    if not state_file.exists():
        return 0

    parts = state_file.read_text().strip().split()
    state_file.unlink(missing_ok=True)
    if not parts or not parts[0].isdigit():
        return 0

    prenum = parts[0]
    prets = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    if prets and time.time() - prets > 3600:
        return 0

    listing = _run(["snapper", "--no-dbus", "-c", "root", "list"]).stdout
    if not any("|" in line and line.split("|")[0].strip() == prenum and " pre " in f" {line} " for line in listing.splitlines()):
        return 0

    _run([
        "snapper",
        "--no-dbus",
        "-c",
        "root",
        "create",
        "-t",
        "post",
        "--pre-number",
        prenum,
        "-p",
        "-d",
        "pacman post",
        "-c",
        "number",
    ])
    return 0


def snapper_plugin(action: str, state_dir_arg: str | None = None, keep: int = 0) -> int:
    _configure_logging()
    if action not in {"create-snapshot-post", "rollback-post", "delete-snapshot-post", "cleanup-post"}:
        return 0
    try:
        return refresh_limine_snapshot_entries(state_dir_arg=state_dir_arg, keep=keep)
    except Exception as exc:
        LOG.error("snapper plugin refresh failed: %s", exc)
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="legion-installer-runtime")
    subparsers = parser.add_subparsers(dest="command", required=True)

    refresh = subparsers.add_parser("refresh-limine-snapshots")
    refresh.add_argument("--state-dir", default=None)
    refresh.add_argument("--keep", type=int, default=0)

    subparsers.add_parser("pacman-pre")
    subparsers.add_parser("pacman-post")

    plugin = subparsers.add_parser("snapper-plugin")
    plugin.add_argument("action")
    plugin.add_argument("--state-dir", default=None)
    plugin.add_argument("--keep", type=int, default=0)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "refresh-limine-snapshots":
        return refresh_limine_snapshot_entries(args.state_dir, args.keep)
    if args.command == "pacman-pre":
        return pacman_pre_snapshot()
    if args.command == "pacman-post":
        return pacman_post_snapshot()
    if args.command == "snapper-plugin":
        return snapper_plugin(args.action, args.state_dir, args.keep)
    parser.error("Unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
