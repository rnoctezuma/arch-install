from .models import (
    BtrfsConfig,
    BootConfig,
    DiskConfig,
    HardwareProfile,
    InstallConfig,
    InstallerPaths,
    LuksConfig,
    PackageConfig,
    SnapperConfig,
    SystemConfig,
)


def default_install_config() -> InstallConfig:
    return InstallConfig(
        hardware=HardwareProfile(
            name="Lenovo Legion i7 Pro Gen 10",
            cpu="Intel Core Ultra 9 275HX",
            gpu="NVIDIA GeForce RTX 5080 Laptop GPU",
            ram="32GB DDR5",
            storage="1TB NVMe Gen 5",
            wifi="Intel Wi-Fi 7",
        ),
        disk=DiskConfig(device=None),
        luks=LuksConfig(),
        btrfs=BtrfsConfig(),
        system=SystemConfig(),
        packages=PackageConfig(),
        boot=BootConfig(),
        snapper=SnapperConfig(),
        installer=InstallerPaths(),
    )
