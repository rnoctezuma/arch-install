## Preparation

Download latest Arch ISO [the official Arch Linux ISO](https://archlinux.org/download/).
Make bootable USB using [balenaEtcher](https://etcher.balena.io/#download-etcher)

### Ensure proper network connectivity

The assumption is that a laptop is being used, intended to connect to the Internet via a wireless connection.

```sh
  1. iwctl
  2. device list

    output example:
    
      Devices
      ----------------------------------------------------------------
      Name   Address            Powered   Adapter   Mode
      ----------------------------------------------------------------
      wlan0  28:0c:50:a6:86:32  off       phy0      station

    NOTE: The Wi-Fi adapter is detected as `wlan0` but currently powered off.
```
