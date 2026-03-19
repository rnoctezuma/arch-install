from __future__ import annotations

import getpass

from .defaults import default_install_config
from .models import InstallConfig, InstallCredentials


class TerminalWizard:
    def _ask(self, prompt: str, default: str | None = None, *, secret: bool = False) -> str:
        suffix = f" [{default}]" if default else ""
        while True:
            if secret:
                value = getpass.getpass(f"{prompt}{suffix}: ").strip()
            else:
                value = input(f"{prompt}{suffix}: ").strip()
            if value:
                return value
            if default is not None:
                return default

    def run(self) -> tuple[InstallConfig, InstallCredentials]:
        config = default_install_config()

        disks_output: list[str] = []
        try:
            import subprocess

            completed = subprocess.run(
                ["lsblk", "-d", "-p", "-n", "-o", "NAME,SIZE,MODEL,TRAN,ROTA", "-e", "7"],
                check=False,
                text=True,
                capture_output=True,
            )
            disks_output = [line for line in completed.stdout.splitlines() if line.strip()]
        except Exception:  # noqa: BLE001
            disks_output = []

        if disks_output:
            print("Available disks:")
            for line in disks_output:
                print(f"  {line}")
        config.disk.device = self._ask("Disk device", "/dev/nvme0n1")

        config.system.hostname = self._ask("Hostname", config.system.hostname)
        config.system.username = self._ask("Username", config.system.username)
        uefi_answer = self._ask("Create UEFI entry? (yes/no)", "yes")
        config.boot.create_uefi_entry = uefi_answer.lower() in {"y", "yes", "true", "1"}

        credentials = InstallCredentials(
            root_password=self._ask("Root password", secret=True),
            user_password=self._ask("User password", secret=True),
            luks_passphrase=self._ask("LUKS passphrase", secret=True),
        )
        return config, credentials
