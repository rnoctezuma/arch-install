from __future__ import annotations

import logging
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

from .exceptions import InstallerError


@dataclass(slots=True)
class CommandResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


class CommandRunner:
    def __init__(self, *, target_mountpoint: str = "/mnt", logger: logging.Logger | None = None):
        self.target_mountpoint = target_mountpoint
        self.logger = logger or logging.getLogger(__name__)

    def require_root(self) -> None:
        if os.geteuid() != 0:
            raise InstallerError("This installer must be run as root.")

    def require_uefi(self) -> None:
        if not Path("/sys/firmware/efi/efivars").exists():
            raise InstallerError("UEFI mode required (/sys/firmware/efi/efivars missing).")

    def require_commands(self, *commands: str) -> None:
        import shutil

        missing = [cmd for cmd in commands if shutil.which(cmd) is None]
        if missing:
            raise InstallerError(f"Missing required commands: {', '.join(missing)}")

    def run(
        self,
        command: Sequence[str] | str,
        *,
        check: bool = True,
        capture_output: bool = True,
        text: bool = True,
        input_text: str | None = None,
        env: Mapping[str, str] | None = None,
        chroot: bool = False,
        shell: bool = False,
    ) -> CommandResult:
        if isinstance(command, str):
            display_command = command
            args: Sequence[str] | str = command
        else:
            display_command = shlex.join(command)
            args = list(command)

        if chroot:
            if shell:
                shell_command = command if isinstance(command, str) else shlex.join(command)
                args = ["arch-chroot", self.target_mountpoint, "/bin/bash", "-lc", shell_command]
            else:
                if isinstance(command, str):
                    raise ValueError("String command with chroot requires shell=True")
                args = ["arch-chroot", self.target_mountpoint, *list(command)]
            display_command = shlex.join(args)
            shell = False

        self.logger.info("RUN %s", display_command)

        completed = subprocess.run(
            args,
            check=False,
            capture_output=capture_output,
            text=text,
            input=input_text,
            env=dict(os.environ) | dict(env or {}),
            shell=shell,
        )

        stdout = completed.stdout or ""
        stderr = completed.stderr or ""

        if stdout:
            self.logger.debug("STDOUT: %s", stdout.strip())
        if stderr:
            self.logger.debug("STDERR: %s", stderr.strip())

        if check and completed.returncode != 0:
            message = f"Command failed ({completed.returncode}): {display_command}"
            if stderr.strip():
                message = f"{message}\n{stderr.strip()}"
            raise InstallerError(message)

        stored_args = list(args) if isinstance(args, list) else [str(args)]
        return CommandResult(stored_args, completed.returncode, stdout, stderr)

    def run_live_shell(self, script: str, *, check: bool = True, input_text: str | None = None) -> CommandResult:
        return self.run(["/bin/bash", "-lc", script], check=check, input_text=input_text)

    def run_chroot_shell(self, script: str, *, check: bool = True, input_text: str | None = None) -> CommandResult:
        return self.run(script, chroot=True, shell=True, check=check, input_text=input_text)


def configure_logging(log_dir: str) -> tuple[logging.Logger, Path]:
    path = Path(log_dir)
    path.mkdir(parents=True, exist_ok=True)
    from datetime import datetime

    log_path = path / f"install-{datetime.now().strftime('%Y%m%d-%H%M%S')}.log"

    logger = logging.getLogger("legion_installer")
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()

    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

    file_handler = logging.FileHandler(log_path)
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setLevel(logging.INFO)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    return logger, log_path
