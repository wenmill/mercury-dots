#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# CACHING
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/../../caching.sh"
qs_ensure_cache "music"

TMP_DIR="$QS_RUN_MUSIC/covers"
STATE_FILE="$QS_STATE_MUSIC/last_state.json"

mkdir -p "$TMP_DIR"
PLACEHOLDER="$TMP_DIR/placeholder_blank.png"

# Prevent cold-boot D-Bus hangs from keeping the script alive
PT="timeout 1.5 playerctl"

# --- 1. ENSURE PLACEHOLDER EXISTS ---
if [ ! -f "$PLACEHOLDER" ]; then
    convert -size 500x500 xc:"#313244" "$PLACEHOLDER"
fi

# --- 2+3. STATUS + INFO IN ONE CALL ---
# One playerctl invocation with a combined format string replaces SIX separate
# D-Bus round-trips (status, artUrl, title, artist, length, position,
# playerName) — this script runs every 500ms, so those forks dominated its
# cost. Fields are joined with the ASCII unit separator (never appears in
# real metadata).
US=$'\x1f'
INFO=$($PT metadata --format "{{status}}${US}{{mpris:artUrl}}${US}{{xesam:title}}${US}{{xesam:artist}}${US}{{mpris:length}}${US}{{position}}${US}{{playerName}}" 2>/dev/null)
IFS="$US" read -r STATUS rawUrl title artist len_micro pos_micro player_raw <<< "$INFO"

if [ "$STATUS" = "Playing" ] || [ "$STATUS" = "Paused" ]; then

    if [ -n "$rawUrl" ]; then
        trackHash=$(echo "$rawUrl" | md5sum | cut -d" " -f1)
    else
        idStr="${title:-unknown}-${artist:-unknown}"
        trackHash=$(echo "$idStr" | md5sum | cut -d" " -f1)
    fi
    
    finalArt="$TMP_DIR/${trackHash}_art.jpg"
    blurPath="$TMP_DIR/${trackHash}_blur.png"
    colorPath="$TMP_DIR/${trackHash}_grad.txt"
    textPath="$TMP_DIR/${trackHash}_text.txt"
    lockFile="$TMP_DIR/${trackHash}.lock"

    displayArt="$PLACEHOLDER"
    displayBlur="$PLACEHOLDER"
    displayGrad="linear-gradient(45deg, #cba6f7, #89b4fa, #f38ba8, #cba6f7)"
    displayText="#cdd6f4"

    # --- 4. ASYNC BACKGROUND LOGIC ---
    if [ -f "$finalArt" ] && [ -s "$finalArt" ]; then
        displayArt="$finalArt"
        if [ -f "$blurPath" ]; then displayBlur="$blurPath"; fi
        if [ -f "$colorPath" ]; then displayGrad=$(cat "$colorPath"); fi
        if [ -f "$textPath" ]; then displayText=$(cat "$textPath"); fi
    else
        if [ ! -f "$lockFile" ] && [ -n "$rawUrl" ]; then
            touch "$lockFile"
            # THE FIX: We redirect standard output/error to /dev/null
            # This severs the pipe to Quickshell, preventing the 30s Qt destructor lockup.
            (
                tempArt="$TMP_DIR/${trackHash}_temp_art.jpg"
                tempBlur="$TMP_DIR/${trackHash}_temp_blur.png"

                if [[ "$rawUrl" == http* ]]; then
                    curl -s -L --max-time 10 -o "$tempArt" "$rawUrl"
                else
                    cleanPath=$(echo "$rawUrl" | sed 's/file:\/\///g')
                    if [ -f "$cleanPath" ]; then
                        cp "$cleanPath" "$tempArt"
                    else
                        cp "$PLACEHOLDER" "$tempArt"
                    fi
                fi

                if [ ! -s "$tempArt" ]; then
                    cp "$PLACEHOLDER" "$tempArt"
                fi

                isPlaceholder=$(convert "$tempArt" -format "%[hex:u.p{0,0}]" info: 2>/dev/null | cut -c1-6)
                
                if [[ "$isPlaceholder" == "313244" ]] || [[ -z "$isPlaceholder" ]]; then
                    cp "$tempArt" "$tempBlur"
                else
                    convert "$tempArt" -blur 0x20 -brightness-contrast -30x-10 "$tempBlur" 2>/dev/null
                    
                    colors=$(convert "$tempArt" -resize 50x50 -alpha off +dither -quantize RGB -colors 3 -depth 8 -format "%c" histogram:info: 2>/dev/null | grep -E -o '#[0-9A-Fa-f]{6}' | head -n 3 | tr '\n' ' ')
                    read -r -a color_array <<< "$colors"
                    
                    c1=${color_array[0]:-#cba6f7}
                    c2=${color_array[1]:-$c1}
                    c3=${color_array[2]:-$c1}
                    
                    echo "linear-gradient(45deg, $c1, $c2, $c3, $c1)" > "$colorPath"
                    
                    opp_raw=$(convert xc:"$c1" -alpha off -negate -depth 8 -format "%[hex:u]" info: 2>/dev/null | grep -E -o '[0-9A-Fa-f]{6}' | head -n 1)
                    if [ -n "$opp_raw" ]; then
                        echo "#$opp_raw" > "$textPath"
                    else
                        echo "#cdd6f4" > "$textPath"
                    fi
                fi

                mv "$tempBlur" "$blurPath"
                mv "$tempArt" "$finalArt"

                rm "$lockFile"
                (cd "$TMP_DIR" && ls -1t | tail -n +21 | xargs -r rm 2>/dev/null)
            ) </dev/null >/dev/null 2>&1 & 
            # ^^^ This is the magic line that fixes the freeze.
        fi
    fi

    # --- 5. TIMING (fields already fetched above) ---
    if [ -z "$len_micro" ] || [ "$len_micro" -eq 0 ]; then len_micro=1000000; fi
    len_sec=$((len_micro / 1000000))
    len_str=$(printf "%02d:%02d" $((len_sec/60)) $((len_sec%60)))

    if [ "$STATUS" = "Playing" ]; then
        if [ -z "$pos_micro" ]; then pos_micro=0; fi
        pos_sec=$((pos_micro / 1000000))

        jq -n -c \
            --argjson pos_sec "$pos_sec" \
            --argjson len_sec "$len_sec" \
            '{pos_sec: $pos_sec, len_sec: $len_sec}' \
            > "$STATE_FILE"
    else
        pos_sec=0
        if [ -f "$STATE_FILE" ]; then
            saved_pos=$(jq -r '.pos_sec' "$STATE_FILE")
            saved_len=$(jq -r '.len_sec' "$STATE_FILE")
            if [ "$saved_len" = "$len_sec" ] && [ -n "$saved_pos" ] && [ "$saved_pos" != "null" ]; then
                pos_sec=$saved_pos
            fi
        fi
    fi

    percent=$((pos_sec * 100 / len_sec))
    pos_str=$(printf "%02d:%02d" $((pos_sec/60)) $((pos_sec%60)))
    time_str="${pos_str} / ${len_str}"

    # --- 6. DEVICE INFO (playerName already fetched above) ---
    player_nice="${player_raw^}"

    # THE FIX: Use native WirePlumber (wpctl) instead of pactl to prevent D-Bus deadlocks.
    # One wpctl call, parsed twice (was two identical invocations).
    dev_icon="󰓃"; dev_name="Speaker"
    wp_out=$(timeout 0.5 wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null)
    node_name=$(awk -F'"' '/node\.name/ {print $2}' <<< "$wp_out")
    node_desc=$(awk -F'"' '/node\.description/ {print $2}' <<< "$wp_out")

    if [[ "$node_name" == *"bluez"* ]]; then
        dev_icon="󰂯"
        [ -n "$node_desc" ] && dev_name="$node_desc" || dev_name="Bluetooth"
    elif [[ "$node_name" == *"usb"* ]]; then
        dev_icon="󰓃"; dev_name="USB Audio"
    elif [[ "$node_name" == *"pci"* ]]; then
        dev_icon="󰓃"; dev_name="System"
    elif [ -n "$node_desc" ]; then
        dev_name="$node_desc"
    fi

    # --- 7. JSON OUTPUT ---
    jq -n -c \
        --arg title "$title" \
        --arg artist "$artist" \
        --arg status "$STATUS" \
        --arg len "$len_sec" \
        --arg pos "$pos_sec" \
        --arg len_str "$len_str" \
        --arg pos_str "$pos_str" \
        --arg time_str "$time_str" \
        --arg percent "$percent" \
        --arg source "$player_nice" \
        --arg pname "$player_raw" \
        --arg blur "$displayBlur" \
        --arg grad "$displayGrad" \
        --arg txtColor "$displayText" \
        --arg devIcon "$dev_icon" \
        --arg devName "$dev_name" \
        --arg finalArt "$displayArt" \
        '{
            title: $title,
            artist: $artist,
            status: $status,
            length: $len,
            position: $pos,
            lengthStr: $len_str,
            positionStr: $pos_str,
            timeStr: $time_str,
            percent: $percent,
            source: $source,
            playerName: $pname,
            blur: $blur,
            grad: $grad,
            textColor: $txtColor,
            deviceIcon: $devIcon,
            deviceName: $devName,
            artUrl: $finalArt
        }'

else
    # --- PiP FALLBACK: the movies widget's embedded mpv has no MPRIS (loading
    # mpv-mpris in-process hangs libmpv inside quickshell), so when no MPRIS
    # player is around, mirror the PiP's state straight off its IPC socket. ---
    PIPSOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mpv-pip.sock"
    pip_json=""
    if [ -S "$PIPSOCK" ]; then
        pip_json=$(python3 - "$PIPSOCK" 2>/dev/null <<'PY'
import json, socket, sys, time
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(0.4); s.connect(sys.argv[1])
    for i, p in enumerate(["media-title", "pause", "time-pos", "duration", "path"]):
        s.sendall((json.dumps({"command": ["get_property", p], "request_id": i}) + "\n").encode())
    vals, seen, buf, end = {}, set(), b"", time.time() + 0.8
    while len(seen) < 5 and time.time() < end:
        try:
            buf += s.recv(4096)
        except socket.timeout:
            break
        lines = buf.split(b"\n"); buf = lines.pop()
        for ln in lines:
            try: d = json.loads(ln)
            except Exception: continue
            rid = d.get("request_id")
            if rid is None: continue     # async events — ignore
            seen.add(rid)
            if d.get("error") == "success":
                vals[rid] = d.get("data")
    # A loaded path is the only hard requirement; pos/duration may still be
    # unavailable while the stream spins up.
    if not vals.get(4):
        raise SystemExit
    print(json.dumps({"title": str(vals.get(0) or "Video"), "pause": bool(vals.get(1)),
                      "pos": float(vals.get(2) or 0), "dur": float(vals.get(3) or 0)}))
except Exception:
    pass
PY
)
    fi
    if [ -n "$pip_json" ]; then
        p_title=$(jq -r '.title' <<<"$pip_json")
        p_pause=$(jq -r '.pause' <<<"$pip_json")
        p_pos=$(jq -r '.pos | floor' <<<"$pip_json")
        p_dur=$(jq -r '.dur | floor' <<<"$pip_json")
        [ -z "$p_dur" ] || [ "$p_dur" -le 0 ] && p_dur=1
        PSTATUS="Playing"; [ "$p_pause" = "true" ] && PSTATUS="Paused"
        percent=$((p_pos * 100 / p_dur))
        pos_str=$(printf "%02d:%02d" $((p_pos/60)) $((p_pos%60)))
        len_str=$(printf "%02d:%02d" $((p_dur/60)) $((p_dur%60)))
        jq -n -c \
            --arg title "$p_title" \
            --arg status "$PSTATUS" \
            --arg len "$p_dur" --arg pos "$p_pos" \
            --arg len_str "$len_str" --arg pos_str "$pos_str" \
            --arg time_str "${pos_str} / ${len_str}" \
            --arg percent "$percent" \
            --arg blur "$PLACEHOLDER" --arg art "$PLACEHOLDER" \
            '{
                title: $title, artist: "Movies · PiP", status: $status,
                length: $len, position: $pos,
                lengthStr: $len_str, positionStr: $pos_str, timeStr: $time_str,
                percent: $percent, source: "Movies", playerName: "mpv-pip",
                blur: $blur, grad: "linear-gradient(45deg, #cba6f7, #89b4fa, #f38ba8, #cba6f7)",
                textColor: "#cdd6f4", deviceIcon: "󰕧", deviceName: "PiP",
                artUrl: $art
            }'
        exit 0
    fi

    # --- FALLBACK (Stopped) ---
    if [ -f "$STATE_FILE" ]; then
        last_pos_sec=$(jq -r '.pos_sec' "$STATE_FILE")
        last_len_sec=$(jq -r '.len_sec' "$STATE_FILE")
    else
        last_pos_sec=0; last_len_sec=0
    fi

    if [ -z "$last_pos_sec" ] || [ "$last_pos_sec" = "null" ]; then last_pos_sec=0; fi
    if [ -z "$last_len_sec" ] || [ "$last_len_sec" = "null" ] || [ "$last_len_sec" -eq 0 ]; then last_len_sec=1; fi

    last_percent=$((last_pos_sec * 100 / last_len_sec))
    last_pos_str=$(printf "%02d:%02d" $((last_pos_sec/60)) $((last_pos_sec%60)))
    last_len_str=$(printf "%02d:%02d" $((last_len_sec/60)) $((last_len_sec%60)))
    last_time_str="${last_pos_str} / ${last_len_str}"

    jq -n -c \
    --arg placeholder "$PLACEHOLDER" \
    --arg pos_str "$last_pos_str" \
    --arg len_str "$last_len_str" \
    --arg time_str "$last_time_str" \
    --arg percent "$last_percent" \
    '{
        title: "Not Playing",
        artist: "",
        status: "Stopped",
        percent: $percent,
        lengthStr: $len_str,
        positionStr: $pos_str,
        timeStr: $time_str,
        source: "Offline",
        playerName: "",
        blur: $placeholder,
        grad: "linear-gradient(45deg, #cba6f7, #89b4fa, #f38ba8, #cba6f7)",
        textColor: "#cdd6f4",
        deviceIcon: "󰓃",
        deviceName: "Speaker",
        artUrl: $placeholder
    }'
fi
