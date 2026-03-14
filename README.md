## Preparation

Download latest Arch ISO [the official Arch Linux ISO](https://archlinux.org/download/).
Make bootable USB using [balenaEtcher](https://etcher.balena.io/#download-etcher)

### Ensure proper network connectivity

WIFI setup

```sh
  1. rfkill unblock all
  2. rfkill list
    - check Soft blocked & Hard blocked = no
  3. iwctl
  4. device list

    output example:
    
      Devices
      ----------------------------------------------------------------
      Name   Address            Powered   Adapter   Mode
      ----------------------------------------------------------------
      wlan0  28:0c:50:a6:86:32  off       phy0      station

    NOTE: The Wi-Fi adapter is detected as `wlan0` but currently powered off.

  5. station <device> connect <SSID>
  6. Ctrl + C -> check internet connection: ping -c 3 archlinux.org
```

### Install

```sh
timedatectl set-ntp true
pacman -Sy --noconfirm git

git clone https://github.com/rnoctezuma/arch-install
cd arch-install
chmod +x install.sh

./install.sh

### WIFI
на установленной системе

nmcli radio wifi on
nmcli device wifi list
sudo nmcli device wifi connect "ИМЯ_СЕТИ" password "ПАРОЛЬ"
ip a
ping -c 2 1.1.1.1
ping -c 2 archlinux.org
```
