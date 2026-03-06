## Preparation

Download latest Arch ISO [the official Arch Linux ISO](https://archlinux.org/download/).
Make bootable USB using [balenaEtcher](https://etcher.balena.io/#download-etcher)

### Ensure proper network connectivity

The assumption is that a laptop is being used, intended to connect to the Internet via a wireless connection.

```sh
  1. iwctl
  2. device list

```markdown
## Wi-Fi Setup (iwd)

Check available wireless devices:

```bash
iwctl device list
(output example):
      
iwctl station <device> connect <SSID>
```
