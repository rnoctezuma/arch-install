#!/bin/bash

echo "Checking internet..."

if ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "Internet OK"
    exit 0
fi

echo "No internet detected."

echo "Available interfaces:"
iwctl device list

echo
read -p "Enter WiFi interface (example: wlan0 or wlp2s0): " IFACE

iwctl station $IFACE scan
sleep 3

iwctl station $IFACE get-networks

echo
read -p "Enter WiFi name (SSID): " SSID

iwctl station $IFACE connect "$SSID"
