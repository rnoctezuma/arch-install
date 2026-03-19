from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path

from .commands import CommandRunner
from .models import InstallConfig, InstallCredentials, InstallerState


@dataclass(slots=True)
class InstallerContext:
    config: InstallConfig
    credentials: InstallCredentials
    state: InstallerState
    runner: CommandRunner
    project_root: Path
    log_path: Path

    @property
    def target_mountpoint(self) -> Path:
        return Path(self.config.installer.target_mountpoint)

    @property
    def live_state_dir(self) -> Path:
        return Path(self.config.installer.state_dir_live)

    @property
    def live_state_file(self) -> Path:
        return self.live_state_dir / "state.json"

    @property
    def target_state_dir(self) -> Path:
        return self.target_mountpoint / self.config.installer.target_state_dir.lstrip("/")

    @property
    def target_runtime_dir(self) -> Path:
        return self.target_mountpoint / self.config.installer.target_runtime_dir.lstrip("/")

    def save_state(self) -> None:
        self.live_state_dir.mkdir(parents=True, exist_ok=True)
        self.state.save(self.live_state_file)

    def sync_state_to_target(self) -> None:
        self.target_state_dir.mkdir(parents=True, exist_ok=True)
        self.save_state()
        shutil.copy2(self.live_state_file, self.target_state_dir / "state.json")

        mapping = {
            "arch_disk": self.state.disk,
            "arch_root_part": self.state.root_partition,
            "arch_mapper": self.state.mapper_name,
        }
        for name, value in mapping.items():
            if value:
                (self.target_state_dir / name).write_text(f"{value}\n")

        (self.target_state_dir / "install-config.json").write_text(json.dumps(self.config.to_dict(), indent=2) + "\n")

    def install_runtime_tree(self) -> None:
        source_pkg = self.project_root / "legion_installer"
        self.target_runtime_dir.mkdir(parents=True, exist_ok=True)
        target_pkg = self.target_runtime_dir / "legion_installer"
        if target_pkg.exists():
            shutil.rmtree(target_pkg)
        shutil.copytree(source_pkg, target_pkg)
