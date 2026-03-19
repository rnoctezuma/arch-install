from __future__ import annotations

import os
from abc import ABC, abstractmethod
from pathlib import Path

from ..context import InstallerContext
from ..exceptions import InstallerError


class Step(ABC):
    name = "unnamed"
    description = ""

    @abstractmethod
    def run(self, ctx: InstallerContext) -> None:
        raise NotImplementedError

    def info(self, ctx: InstallerContext, message: str) -> None:
        ctx.runner.logger.info("[%s] %s", self.name, message)

    def warn(self, ctx: InstallerContext, message: str) -> None:
        ctx.runner.logger.warning("[%s] %s", self.name, message)

    def require_state(self, ctx: InstallerContext, *fields: str) -> None:
        missing = [field for field in fields if not getattr(ctx.state, field)]
        if missing:
            raise InstallerError(f"Step {self.name} requires state fields: {', '.join(missing)}")


def ask_yes_no(prompt: str, *, default: bool = False) -> bool:
    if not os.isatty(0):
        return default
    suffix = "[Y/n]" if default else "[y/N]"
    answer = input(f"{prompt} {suffix} ").strip().lower()
    if not answer:
        return default
    return answer in {"y", "yes"}


def ask_required(prompt: str, default: str | None = None) -> str:
    if default is not None:
        full_prompt = f"{prompt} [{default}]: "
    else:
        full_prompt = f"{prompt}: "
    while True:
        value = input(full_prompt).strip()
        if value:
            return value
        if default is not None:
            return default


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)
