from __future__ import annotations

import json
import re
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class HardwareProfile:
    name: str
    cpu: str
    gpu: str
    ram: str
    storage: str
    wifi: str


@dataclass(slots=True)
class DiskConfig:
    device: str | None = None
    esp_start: str = "1MiB"
    esp_end: str = "2049MiB"
    esp_label: str = "EFI"
    root_label: str = "ROOT"
    force: bool = False


@dataclass(slots=True)
class LuksConfig:
    mapper_name: str = "cryptroot"
    pbkdf_memory_kib: int = 262144
    iter_time_ms: int = 2000
    cipher: str = "aes-xts-plain64"
    key_size: int = 512
    hash_name: str = "sha512"
    pbkdf: str = "argon2id"
    allow_discards: bool = True


@dataclass(slots=True)
class BtrfsConfig:
    filesystem_label: str = "arch"
    subvolumes: list[str] = field(default_factory=lambda: ["@", "@home", "@log", "@cache", "@snapshots"])
    mount_options: list[str] = field(
        default_factory=lambda: [
            "noatime",
            "compress=zstd:1",
            "space_cache=v2",
            "discard=async",
            "commit=120",
        ]
    )


@dataclass(slots=True)
class SystemConfig:
    timezone: str = "Asia/Ho_Chi_Minh"
    locale: str = "en_US.UTF-8"
    keymap: str = "us"
    hostname: str = "arch"
    username: str = "rnoct"
    shell: str = "/bin/bash"
    enable_multilib: bool = True


@dataclass(slots=True)
class PackageConfig:
    mirrorlist: list[str] = field(
        default_factory=lambda: [
            "https://mirrors.huongnguyen.dev/arch/$repo/os/$arch",
            "https://mirrors.nguyenhoang.cloud/archlinux/$repo/os/$arch",
            "https://download.nus.edu.sg/mirror/archlinux/$repo/os/$arch",
            "https://mirror.aktkn.sg/archlinux/$repo/os/$arch",
        ]
    )
    base: list[str] = field(
        default_factory=lambda: [
            "base",
            "base-devel",
            "linux-zen",
            "linux-lts",
            "linux-firmware",
            "btrfs-progs",
            "networkmanager",
            "sudo",
            "intel-ucode",
            "mkinitcpio",
            "python",
        ]
    )
    essential: list[str] = field(
        default_factory=lambda: [
            "nano",
            "git",
            "htop",
            "fastfetch",
            "mesa",
            "vulkan-icd-loader",
            "dosfstools",
            "pacman-contrib",
            "efibootmgr",
            "dkms",
            "linux-zen-headers",
            "linux-lts-headers",
            "nvidia-open-dkms",
            "nvidia-utils",
            "lib32-nvidia-utils",
            "nvidia-settings",
        ]
    )


@dataclass(slots=True)
class BootConfig:
    timeout_seconds: int = 3
    create_uefi_entry: bool = True
    prefer_kernel: str = "linux-zen"
    include_lts_if_available: bool = True
    cmdline_quiet: str = (
        "quiet loglevel=3 nowatchdog mitigations=off nvme_core.default_ps_max_latency_us=0 nvidia-drm.modeset=1"
    )
    fallback_cmdline_extra: str = "nvidia-drm.modeset=1"


@dataclass(slots=True)
class SnapperConfig:
    timeline_hourly: int = 4
    timeline_daily: int = 5
    timeline_weekly: int = 3
    timeline_monthly: int = 1
    number_limit: int = 20
    plugin_keep_snapshots: int = 0


@dataclass(slots=True)
class InstallerPaths:
    target_mountpoint: str = "/mnt"
    state_dir_live: str = "/tmp/legion-installer"
    log_dir: str = "/var/log/legion-installer"
    target_runtime_dir: str = "/usr/local/share/legion-installer"
    target_state_dir: str = "/root/arch-install-state"


@dataclass(slots=True)
class InstallCredentials:
    root_password: str | None = None
    user_password: str | None = None
    luks_passphrase: str | None = None

    @classmethod
    def from_file(cls, path: str | Path) -> "InstallCredentials":
        data = load_structured_file(path)
        return cls(
            root_password=data.get("root_password"),
            user_password=data.get("user_password"),
            luks_passphrase=data.get("luks_passphrase"),
        )


@dataclass(slots=True)
class InstallConfig:
    hardware: HardwareProfile
    disk: DiskConfig
    luks: LuksConfig
    btrfs: BtrfsConfig
    system: SystemConfig
    packages: PackageConfig
    boot: BootConfig
    snapper: SnapperConfig
    installer: InstallerPaths

    def validate(self) -> None:
        if self.disk.device is not None and not self.disk.device.startswith("/dev/"):
            raise ValueError(f"Disk must be a /dev path, got: {self.disk.device}")
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$", self.system.hostname):
            raise ValueError(f"Invalid hostname: {self.system.hostname}")
        if not re.match(r"^[a-z_][a-z0-9_-]*$", self.system.username):
            raise ValueError(f"Invalid username: {self.system.username}")
        if self.boot.timeout_seconds < 0:
            raise ValueError("Boot timeout must be >= 0")
        if self.snapper.number_limit < 1:
            raise ValueError("Snapper number_limit must be >= 1")

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_file(cls, path: str | Path) -> "InstallConfig":
        return cls.from_dict(load_structured_file(path))

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "InstallConfig":
        return cls(
            hardware=HardwareProfile(**data["hardware"]),
            disk=DiskConfig(**data["disk"]),
            luks=LuksConfig(**data["luks"]),
            btrfs=BtrfsConfig(**data["btrfs"]),
            system=SystemConfig(**data["system"]),
            packages=PackageConfig(**data["packages"]),
            boot=BootConfig(**data["boot"]),
            snapper=SnapperConfig(**data["snapper"]),
            installer=InstallerPaths(**data["installer"]),
        )


@dataclass(slots=True)
class InstallerState:
    disk: str | None = None
    root_partition: str | None = None
    mapper_name: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_file(cls, path: str | Path) -> "InstallerState":
        return cls(**json.loads(Path(path).read_text()))

    def save(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps(self.to_dict(), indent=2) + "\n")


def load_structured_file(path: str | Path) -> dict[str, Any]:
    path = Path(path)
    text = path.read_text()
    if path.suffix == ".json":
        return json.loads(text)
    if path.suffix in {".toml", ".tml"}:
        return tomllib.loads(text)
    raise ValueError(f"Unsupported config format: {path.suffix}")
