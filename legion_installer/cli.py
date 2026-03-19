from __future__ import annotations

import argparse
import traceback

from .app import InstallerApp
from .exceptions import InstallerError
from .models import InstallConfig, InstallCredentials
from .ui import TerminalWizard


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="legion-installer")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("guided", help="Run guided terminal wizard")

    install = subparsers.add_parser("install", help="Run installer from config files")
    install.add_argument("--config", required=True)
    install.add_argument("--credentials")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "guided":
            config, credentials = TerminalWizard().run()
            InstallerApp(config, credentials).run()
            return 0

        if args.command == "install":
            config = InstallConfig.from_file(args.config)
            credentials = InstallCredentials.from_file(args.credentials) if args.credentials else InstallCredentials()
            InstallerApp(config, credentials).run()
            return 0

        parser.error("Unknown command")
        return 2
    except (InstallerError, ValueError) as exc:
        print(f"ERROR: {exc}")
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"UNEXPECTED ERROR: {exc}")
        traceback.print_exc()
        return 1
