#!/usr/bin/env bash

# --- CONFIGURATION ---
STRICT_SPAM_FILTER=true
# ---------------------

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/../../caching.sh"
qs_ensure_cache "network"

CACHE_DIR="$QS_CACHE_NETWORK"
PID_FILE="$QS_RUN_DIR/bt_scan_pid"

get_icon() {
    local type="${1,,}"
    local name="${2,,}"
    if [[ "$type" == *"headset"* || "$type" == *"headphone"* || "$name" == *"headphone"* || "$name" == *"buds"* || "$name" == *"pods"* ]]; then echo "🎧"
    elif [[ "$type" == *"audio"* || "$type" == *"speaker"* || "$type" == *"card"* || "$name" == *"speaker"* ]]; then echo "蓼"
    elif [[ "$type" == *"phone"* || "$name" == *"phone"* || "$name" == *"iphone"* || "$name" == *"android"* ]]; then echo ""
    elif [[ "$type" == *"mouse"* || "$name" == *"mouse"* ]]; then echo ""
    elif [[ "$type" == *"keyboard"* || "$name" == *"keyboard"* ]]; then echo ""
    elif [[ "$type" == *"controller"* || "$name" == *"controller"* ]]; then echo ""
    else echo ""
    fi
}

get_audio_profile() {
    local mac="$1"
    local cards_data="$2"
    local mac_us="${mac//:/_}"
    
    local active=$(echo "$cards_data" | awk -v mac="$mac_us" '
        tolower($0) ~ "name:.*"tolower(mac) { found=1 }
        found && tolower($0) ~ "active profile:" { 
            sub(/.*Active Profile: /, ""); print; exit 
        }
        found && /^$/ { exit }
    ')
    
    if [[ -z "$active" || "$active" == "off" ]]; then echo "None"; return; fi
    if [[ "$active" == *"a2dp"* ]]; then echo "Hi-Fi (A2DP)"; return; fi
    if [[ "$active" == *"headset"* || "$active" == *"hfp"* ]]; then echo "Headset (HFP)"; return; fi
    
    echo "Connected"
}

get_status() {
    # 1. Zero-latency hardware presence check (Bypasses the 1-second timeout entirely)
    if ! ls -1d /sys/class/bluetooth/hci* &>/dev/null; then
        echo "{\"present\":false,\"power\":\"off\",\"connected\":[],\"devices\":[]}"
        return
    fi

    # 2. Check if bluetoothctl is even installed to prevent command errors
    if ! command -v bluetoothctl &> /dev/null; then
        echo "{\"present\":false,\"power\":\"off\",\"connected\":[],\"devices\":[]}"
        return
    fi

    # Presence is already PROVEN by the sysfs hci* check above. Do NOT re-derive it
    # from `bluetoothctl list` — that command transiently times out / returns empty
    # while bluetoothd is busy (scanning, connecting, or just slow), which used to
    # flip present:false and make the whole Bluetooth module vanish "half the time".
    # bluez readiness only affects power/devices below, never presence.

    power="off"
    if timeout 1 bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then power="on"; fi

    connected_json="[]"
    devices_json="[]"

    if [ "$power" == "on" ]; then
        # Strip ANSI colour codes from bluetoothctl output. Newer BlueZ colours
        # device lines (e.g. gray for out-of-range), and the raw ESC bytes are
        # illegal control characters in JSON — they used to break JSON.parse on the
        # QML side and make the module vanish whenever a coloured device appeared.
        strip_ansi() { sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

        paired_macs=$(bluetoothctl devices Paired 2>/dev/null | strip_ansi)
        mapfile -t devices < <(bluetoothctl devices 2>/dev/null | strip_ansi)
        mapfile -t connected_info_lines < <(bluetoothctl devices Connected 2>/dev/null | strip_ansi)
        
        # THE FIX: Cache pactl output ONCE per script execution with a strict timeout
        cached_cards=$(timeout 0.5 pactl list cards 2>/dev/null)
        
        connected_macs=""
        connected_list_objs=()
        devices_list_objs=()

        # AirPods telemetry from the LibrePods producer (airpods_librepods.sh).
        # Read once; merged below into the matching connected device if fresh (<10 min).
        AIRPODS_STATE="$HOME/.cache/qs_airpods.json"
        ap_mac=""; ap_conn="false"; ap_age=999999; ap_l=0; ap_r=0; ap_c=0; ap_anc=""
        if [ -f "$AIRPODS_STATE" ] && command -v jq &>/dev/null; then
            read -r ap_mac ap_conn ap_age ap_l ap_r ap_c ap_anc < <(
                jq -r --argjson now "$(date +%s)" \
                   '[.mac//"", (.connected//false|tostring), ($now-(.ts//0)), .left//0, .right//0, .case//0, .anc//""] | @tsv' \
                   "$AIRPODS_STATE" 2>/dev/null)
        fi

        # 1. PROCESS CONNECTED DEVICES
        for c_line in "${connected_info_lines[@]}"; do
            [ -z "$c_line" ] && continue
            rest="${c_line#Device }"
            mac="${rest%% *}"
            name="${rest#* }"
            connected_macs+="$mac "
            
            CACHE_FILE="$CACHE_DIR/bt_stat_${mac//:/_}"

            if [ -f "$CACHE_FILE" ]; then
                source "$CACHE_FILE"
            else
                info=$(bluetoothctl info "$mac" 2>/dev/null | strip_ansi)
                icon_type=$(echo "$info" | awk -F': ' '/Icon:/ {print $2}')
                icon=$(get_icon "$icon_type" "$name")
                
                # THE FIX: Pass the cached output instead of calling pactl again
                profile=$(get_audio_profile "$mac" "$cached_cards")
                
                echo "CACHE_NAME=\"${name//\"/\\\"}\"" > "$CACHE_FILE"
                echo "CACHE_ICON=\"${icon//\"/\\\"}\"" >> "$CACHE_FILE"
                echo "CACHE_PROFILE=\"${profile//\"/\\\"}\"" >> "$CACHE_FILE"
                
                CACHE_NAME="${name//\"/\\\"}"
                CACHE_ICON="${icon//\"/\\\"}"
                CACHE_PROFILE="${profile//\"/\\\"}"
            fi
            
            bat=$(bluetoothctl info "$mac" 2>/dev/null | strip_ansi | awk -F'[(|)]' '/Battery Percentage:/ {print $2}')
            [ -z "$bat" ] && bat="0"

            # Merge AirPods left/right/case/anc when LibrePods reports this device, fresh.
            extra=""
            if [ "$ap_conn" == "true" ] && [ "$ap_mac" == "$mac" ] && [ "$ap_age" -lt 600 ] 2>/dev/null; then
                extra=",\"left\":$ap_l,\"right\":$ap_r,\"case\":$ap_c,\"anc\":\"$ap_anc\""
            fi

            connected_list_objs+=("{\"id\":\"$mac\",\"name\":\"$CACHE_NAME\",\"mac\":\"$mac\",\"icon\":\"$CACHE_ICON\",\"battery\":\"$bat\",\"profile\":\"$CACHE_PROFILE\"$extra}")
        done

        if [ ${#connected_list_objs[@]} -gt 0 ]; then
            connected_json="[$(IFS=,; echo "${connected_list_objs[*]}")]"
        fi

        # 2. PROCESS DISCOVERED & PAIRED DEVICES
        for line in "${devices[@]}"; do
            [ -z "$line" ] && continue
            rest="${line#Device }"
            mac="${rest%% *}"
            
            if [[ "$connected_macs" == *"$mac"* ]]; then continue; fi

            name="${rest#* }"
            name_esc="${name//\"/\\\"}"

            if [[ "$paired_macs" == *"$mac"* ]]; then
                action="Connect"
            else
                action="Pair"
                if [[ "$STRICT_SPAM_FILTER" == true ]]; then
                    mac_hyphens="${mac//:/-}"
                    if [[ "$name" == "$mac" || "$name" == "$mac_hyphens" || -z "$name" ]]; then
                        continue
                    fi
                fi
            fi

            icon=$(get_icon "unknown" "$name")
            icon_esc="${icon//\"/\\\"}"

            devices_list_objs+=("{\"id\":\"$mac\",\"name\":\"$name_esc\",\"mac\":\"$mac\",\"icon\":\"$icon_esc\",\"action\":\"$action\"}")
        done

        if [ ${#devices_list_objs[@]} -gt 0 ]; then
            devices_json="[$(IFS=,; echo "${devices_list_objs[*]}")]"
        fi
    fi

    echo "{\"present\":true,\"power\":\"$power\",\"connected\":$connected_json,\"devices\":$devices_json}"
}

toggle_power() {
    if bluetoothctl show | grep -q "Powered: yes"; then
        bluetoothctl power off
    else
        bluetoothctl power on
    fi
    sleep 0.5
}

connect_dev() {
    local mac="$1"
    if [ -f "$PID_FILE" ]; then kill -STOP $(cat "$PID_FILE") 2>/dev/null; fi
    bluetoothctl trust "$mac" > /dev/null 2>&1
    bluetoothctl connect "$mac"
    if [ -f "$PID_FILE" ]; then kill -CONT $(cat "$PID_FILE") 2>/dev/null; fi
}

disconnect_dev() {
    local mac="$1"
    rm -f "$CACHE_DIR/bt_stat_${mac//:/_}" 2>/dev/null
    bluetoothctl disconnect "$mac"
}

cmd="$1"
case $cmd in
    --status) get_status ;;
    --toggle) toggle_power ;;
    --connect) connect_dev "$2" ;;
    --disconnect) disconnect_dev "$2" ;;
esac
