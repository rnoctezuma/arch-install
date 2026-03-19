from __future__ import annotations

from pathlib import Path

from ..exceptions import InstallerError
from .base import Step, ask_yes_no


class LuksStep(Step):
    name = "02_luks"
    description = "Format ROOT as LUKS2 and open mapper"

    def _choose_mapper_name(self, ctx) -> str:
        base = ctx.config.luks.mapper_name
        if not Path(f"/dev/mapper/{base}").exists():
            return base
        for idx in range(1, 10):
            candidate = f"{base}{idx}"
            if not Path(f"/dev/mapper/{candidate}").exists():
                return candidate
        raise InstallerError("No free mapper name available")

    def _pbkdf_parallel(self, ctx) -> str:
        result = ctx.runner.run(["nproc"], check=False)
        cores = int(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip().isdigit() else 4
        return str(max(1, min(cores, 4)))

    def run(self, ctx) -> None:
        self.require_state(ctx, "disk", "root_partition")
        root_part = ctx.state.root_partition or ""
        if not Path(root_part).exists():
            raise InstallerError(f"Root partition not found: {root_part}")

        if any(line.split()[0] == root_part for line in Path("/proc/mounts").read_text().splitlines() if line.split()):
            raise InstallerError(f"Root partition appears mounted: {root_part}")
        if any(line.split()[0] == root_part for line in Path("/proc/swaps").read_text().splitlines()[1:] if line.split()):
            raise InstallerError(f"Root partition appears used as swap: {root_part}")

        mapper_name = self._choose_mapper_name(ctx)
        pbkdf_parallel = self._pbkdf_parallel(ctx)

        is_luks = ctx.runner.run(["cryptsetup", "isLuks", root_part], check=False).returncode == 0
        if is_luks and not ask_yes_no(f"Existing LUKS header detected on {root_part}. Overwrite?", default=False):
            raise InstallerError("Aborted by user.")

        if not ctx.credentials.luks_passphrase:
            if not ask_yes_no(f"Encrypt {root_part} with LUKS2?", default=False):
                raise InstallerError("Aborted by user.")
            ctx.runner.run(
                [
                    "cryptsetup",
                    "luksFormat",
                    "--type",
                    "luks2",
                    "--label",
                    "cryptroot",
                    "--cipher",
                    ctx.config.luks.cipher,
                    "--key-size",
                    str(ctx.config.luks.key_size),
                    "--hash",
                    ctx.config.luks.hash_name,
                    "--pbkdf",
                    ctx.config.luks.pbkdf,
                    "--pbkdf-memory",
                    str(ctx.config.luks.pbkdf_memory_kib),
                    "--pbkdf-parallel",
                    pbkdf_parallel,
                    "--iter-time",
                    str(ctx.config.luks.iter_time_ms),
                    "--verify-passphrase",
                    root_part,
                ],
                capture_output=False,
            )
            open_command = ["cryptsetup", "open", root_part, mapper_name]
            if ctx.config.luks.allow_discards:
                open_command.insert(2, "--allow-discards")
            ctx.runner.run(open_command, capture_output=False)
        else:
            passphrase = ctx.credentials.luks_passphrase + "\n"
            ctx.runner.run(
                [
                    "cryptsetup",
                    "luksFormat",
                    "--batch-mode",
                    "--key-file",
                    "-",
                    "--type",
                    "luks2",
                    "--label",
                    "cryptroot",
                    "--cipher",
                    ctx.config.luks.cipher,
                    "--key-size",
                    str(ctx.config.luks.key_size),
                    "--hash",
                    ctx.config.luks.hash_name,
                    "--pbkdf",
                    ctx.config.luks.pbkdf,
                    "--pbkdf-memory",
                    str(ctx.config.luks.pbkdf_memory_kib),
                    "--pbkdf-parallel",
                    pbkdf_parallel,
                    "--iter-time",
                    str(ctx.config.luks.iter_time_ms),
                    root_part,
                ],
                input_text=passphrase,
            )
            open_command = ["cryptsetup", "open", "--key-file", "-", root_part, mapper_name]
            if ctx.config.luks.allow_discards:
                open_command.insert(2, "--allow-discards")
            ctx.runner.run(open_command, input_text=passphrase)

        if not Path(f"/dev/mapper/{mapper_name}").exists():
            raise InstallerError(f"Failed to open LUKS mapper: {mapper_name}")

        ctx.state.mapper_name = mapper_name
        ctx.save_state()
        self.info(ctx, f"Opened mapper: {mapper_name}")
