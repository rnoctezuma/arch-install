from __future__ import annotations

from .base import Step, ask_yes_no


class UefiEntryStep(Step):
    name = "07_uefi_entry"
    description = "Create optional UEFI NVRAM entry for Limine"

    def run(self, ctx) -> None:
        self.require_state(ctx, "disk")
        if not ctx.config.boot.create_uefi_entry:
            self.info(ctx, "Skipping UEFI entry creation by config")
            return

        listing = ctx.runner.run(["efibootmgr", "-v"], check=False).stdout.lower()
        if r"file(\efi\boot\bootx64.efi)" in listing:
            self.info(ctx, "UEFI entry already exists; skipping")
            return

        if not ask_yes_no("Create UEFI NVRAM entry for Limine?", default=True):
            self.info(ctx, "User skipped UEFI entry creation")
            return

        ctx.runner.run(
            [
                "efibootmgr",
                "--create",
                "--disk",
                ctx.state.disk or "",
                "--part",
                "1",
                "--label",
                "Arch Linux (Limine)",
                "--loader",
                r"\EFI\BOOT\BOOTX64.EFI",
            ],
            check=False,
        )
        self.info(ctx, "UEFI entry creation attempted")
