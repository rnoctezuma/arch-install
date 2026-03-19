from __future__ import annotations

from pathlib import Path

from .commands import CommandRunner, configure_logging
from .context import InstallerContext
from .defaults import default_install_config
from .models import InstallConfig, InstallCredentials, InstallerState
from .steps import (
    BaseInstallStep,
    BootloaderStep,
    BtrfsStep,
    DiskPartitionStep,
    LuksStep,
    SnapperHookStep,
    SnapperSetupStep,
    SnapshotEntriesStep,
    SystemConfigStep,
    UefiEntryStep,
)


class InstallerApp:
    def __init__(self, config: InstallConfig | None = None, credentials: InstallCredentials | None = None):
        self.config = config or default_install_config()
        self.credentials = credentials or InstallCredentials()
        self.config.validate()
        logger, log_path = configure_logging(self.config.installer.log_dir)
        self.ctx = InstallerContext(
            config=self.config,
            credentials=self.credentials,
            state=InstallerState(),
            runner=CommandRunner(target_mountpoint=self.config.installer.target_mountpoint, logger=logger),
            project_root=Path(__file__).resolve().parent.parent,
            log_path=log_path,
        )
        self.steps = [
            DiskPartitionStep(),
            LuksStep(),
            BtrfsStep(),
            BaseInstallStep(),
            SystemConfigStep(),
            BootloaderStep(),
            UefiEntryStep(),
            SnapshotEntriesStep(),
            SnapperSetupStep(),
            SnapperHookStep(),
        ]


    def run(self) -> Path:
        self.ctx.runner.logger.info("Log file: %s", self.ctx.log_path)
        for step in self.steps:
            self.ctx.runner.logger.info("==== %s ====", step.name)
            step.run(self.ctx)
        self.ctx.runner.logger.info("Installer finished successfully")
        return self.ctx.log_path
