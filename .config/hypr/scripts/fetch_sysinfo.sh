#!/usr/bin/env bash
# ~/.config/hypr/scripts/quickshell/battery/fetch_sysinfo.sh
echo "OS:$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
echo "KERNEL:$(uname -r)"
echo "SHELL:$(basename "$SHELL")"
echo "CPU_NAME:$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //;s/(R)//;s/(TM)//;s/CPU //')"
echo "GPU:$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/.*: //;s/ (rev.*//')"
echo "MEMORY:$(free -h 2>/dev/null | awk '/^Mem:/{print $3 " / " $2}')"
echo "DISK:$(df -h / 2>/dev/null | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
echo "PACKAGES:$(pacman -Q 2>/dev/null | wc -l || echo 0) pkgs"
echo "TERMINAL:$(ps -p "$(ps -p $$ -o ppid= 2>/dev/null)" -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo unknown)"
echo "WM:Hyprland $(hyprctl version 2>/dev/null | grep -oP 'v[0-9.]+' | head -1)"
echo "RESOLUTION:$(hyprctl monitors 2>/dev/null | grep -oP '\d+x\d+@\d+' | head -1 | sed 's/@/ @ /;s/$/ Hz/')"
echo "LOCALE:$(locale 2>/dev/null | grep '^LANG=' | cut -d= -f2 | cut -d. -f1)"
