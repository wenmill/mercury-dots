#!/usr/bin/env bash
# ~/.config/hypr/scripts/quickshell/battery/fetch_sysinfo.sh
echo "OS:$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
echo "KERNEL:$(uname -r)"
echo "SHELL:$(basename "$SHELL")"
# CPU/GPU: strip vendor/marketing cruft so the whole name fits (no ElideRight clip).
# CPU  "AMD Ryzen 7 7800X3D 8-Core Processor" -> "Ryzen 7 7800X3D"; Intel "Core i7-9750H".
# GPU  pulls the marketing name from the last [..] in lspci -> "Radeon RX 9060 XT" /
#      "GeForce RTX 3070"; falls back to a vendor-stripped name when there's no bracket.
echo "CPU_NAME:$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed -E 's/^ *//;s/\(R\)//g;s/\(TM\)//g;s/ @ [0-9.]+GHz//;s/ [0-9]+-Core Processor//;s/ Processor$//;s/ CPU$//;s/^AMD //;s/^Intel //')"
echo "GPU:$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed -E 's/.*controller: //;s/ \(rev.*//;s/.*\[([^][]+)\][^][]*$/\1/;s/Advanced Micro Devices, Inc\. //;s#\[AMD/ATI\] ##;s/NVIDIA Corporation //;s/Intel Corporation //')"
echo "MEMORY:$(free -h 2>/dev/null | awk '/^Mem:/{print $3 " / " $2}')"
echo "DISK:$(df -h / 2>/dev/null | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
echo "PACKAGES:$(pacman -Q 2>/dev/null | wc -l || echo 0) pkgs"
echo "TERMINAL:$(ps -p "$(ps -p $$ -o ppid= 2>/dev/null)" -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo unknown)"
echo "WM:Hyprland $(hyprctl version 2>/dev/null | grep -oP 'v[0-9.]+' | head -1)"
echo "RESOLUTION:$(hyprctl monitors 2>/dev/null | grep -oP '\d+x\d+@\d+' | head -1 | sed 's/@/ @ /;s/$/ Hz/')"
echo "LOCALE:$(locale 2>/dev/null | grep '^LANG=' | cut -d= -f2 | cut -d. -f1)"
