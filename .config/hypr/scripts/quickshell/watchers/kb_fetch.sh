#!/usr/bin/env bash
# Report the active input mode for the topbar label.
# With fcitx5 running, `fcitx5-remote` prints: 2 = IME active (Mozc/Japanese),
# 1 = inactive (English/latin), 0 = fcitx not ready. JP when Mozc is active,
# otherwise EN. Falls back to the raw xkb layout if fcitx5 isn't up yet.
if command -v fcitx5-remote >/dev/null 2>&1; then
    case "$(fcitx5-remote 2>/dev/null)" in
        2) echo "JP"; exit 0 ;;
        1) echo "EN"; exit 0 ;;
    esac
fi

layout=$(LC_ALL=C hyprctl devices -j 2>/dev/null | jq -r '(.keyboards[] | select(.main == true) | .active_keymap) // .keyboards[0].active_keymap // empty' | head -n1)
[[ -z "$layout" || "$layout" == "null" ]] && layout="US"
echo "${layout:0:2}" | tr '[:lower:]' '[:upper:]'
