#!/usr/bin/env bash
#
# Toggle the AirPods between this PC and the phone with a single keybind.
#
#   - Currently connected to this PC  -> disconnect (hand them back to the phone)
#   - Not connected to this PC        -> connect (grab them from the phone)
#
# Note: AirPods don't do multipoint with non-Apple hosts, so "release" just frees
# the link; the phone reconnects on its own (or tap them in its Bluetooth menu).

# Device MAC comes from config.json ("airpods_mac") — a personal hardware
# identifier has no business being hardcoded in a distributable script.
MAC="$(jq -r '.airpods_mac // empty' "$HOME/.config/hypr/config.json" 2>/dev/null)"
[ -z "$MAC" ] && { notify-send "AirPods" "Set \"airpods_mac\" in ~/.config/hypr/config.json"; exit 0; }
ICON="audio-headphones"

# BlueZ reports Connected: yes only when *this* adapter holds the link.
state=$(bluetoothctl info "$MAC" 2>/dev/null | awk -F': ' '/Connected:/{print $2; exit}')

if [ "$state" = "yes" ]; then
    if bluetoothctl disconnect "$MAC" >/dev/null 2>&1; then
        notify-send -i "$ICON" "AirPods" "Released — grab them on your phone"
    else
        notify-send -u critical -i "$ICON" "AirPods" "Could not release them"
    fi
else
    if bluetoothctl connect "$MAC" >/dev/null 2>&1; then
        notify-send -i "$ICON" "AirPods" "Switched to this PC"
    else
        notify-send -u critical -i "$ICON" "AirPods" "Could not grab them — free them on your phone first"
    fi
fi
