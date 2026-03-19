# Legion Arch Installer

Opinionated Arch Linux installer written in Python for a **single target machine**:

- Lenovo Legion i7 Pro Gen 10
- Intel Core Ultra 9 275HX
- NVIDIA RTX 5080 Laptop GPU
- LUKS2
- Btrfs
- Limine
- Snapper
- Arch Linux base with `linux-zen` + `linux-lts`

The project keeps the logic of the original 10-step shell installer, but moves it into:

- typed dataclasses
- a single orchestrator
- reusable step classes
- a state model instead of ad-hoc tmp files
- a minimal guided terminal wizard in the spirit of `archinstall`

## Main commands

Guided install:

```bash
python -m legion_installer guided
```

Non-interactive install:

```bash
python -m legion_installer install --config examples/profile.json --credentials examples/credentials.json
```

## What `examples/` is for

The `examples/` folder is a ready-made template for **non-interactive** installs.

- `examples/profile.json` stores the full machine profile: disk layout, mirrors, packages, mkinitcpio-related boot settings, Limine cmdline, Snapper retention, and installer paths.
- `examples/credentials.json` stores secrets separately: root password, user password, and LUKS passphrase.

Why keep it:

- you can reuse one stable hardware/profile file for repeated installs
- you can swap only passwords without touching the machine config
- it shows every supported config field in one place
- it gives you the simplest unattended install path later

Practical note: `examples/credentials.json` is a template. Replace `CHANGE_ME` before a real install and do not commit real passwords.

## Notes

- Runtime helpers for pacman hooks and snapper plugins are installed into the target system under `/usr/local/share/legion-installer`.
- The installer deliberately adds the `python` package to the target base system, because the pacman hooks and Limine snapshot refresh runtime are Python-based.
- The guided wizard is a minimal terminal UI, not a full graphical desktop app.
- Current defaults match the refreshed shell installer, including `nvidia-open-dkms`, `nvidia-utils`, `lib32-nvidia-utils`, `nvidia-settings`, and `nvidia-drm.modeset=1` in Limine cmdline generation.

## Safety model

The installer still performs destructive actions. It:

- requires root
- checks for UEFI
- refuses to touch the live ISO disk
- asks for confirmation before destructive disk operations unless explicit config flags are enabled
- logs everything into `/var/log/legion-installer`
