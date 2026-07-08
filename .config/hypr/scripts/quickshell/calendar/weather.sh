#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# CACHING & MIGRATION
# -----------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/../../caching.sh"
qs_ensure_cache "weather"

# Force standard C locale for number formatting and date parsing (fixes printf and date command issues on varying OS locales)
export LC_ALL=C

# Paths
cache_dir="$QS_CACHE_WEATHER"
json_file="${cache_dir}/weather.json"
view_file="${cache_dir}/view_id"
daily_cache_file="${cache_dir}/daily_weather_cache.json"
next_day_cache_file="${cache_dir}/next_day_precache.json"
ENV_FILE="$(dirname "$0")/.env"

# API Settings
# Load environment variables silently. Sourced with allexport rather than
# `export $(grep … | xargs)`, which word-splits values and would export ANY
# variable in the file (including ones like PATH) through xargs quoting rules.
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
fi

# API Settings from .env
KEY="$OPENWEATHER_KEY"
ID="$OPENWEATHER_CITY_ID"
UNIT="${OPENWEATHER_UNIT:-metric}" # Default to metric if not set

# Determine temperature symbol based on unit
case "$UNIT" in
    "imperial") UNIT_SYM="°F" ;;
    "standard") UNIT_SYM="K" ;;
    *) UNIT_SYM="°C" ;;
esac

mkdir -p "${cache_dir}"

get_icon() {
    case $1 in
        "50d"|"50n") icon="󰖑"; quote="Mist" ;;
        "01d") icon=""; quote="Sunny" ;;
        "01n") icon=""; quote="Clear" ;;
        "02d"|"02n"|"03d"|"03n"|"04d"|"04n") icon=""; quote="Cloudy" ;;
        "09d"|"09n"|"10d"|"10n") icon="󰖗"; quote="Rainy" ;;
        "11d"|"11n") icon=""; quote="Storm" ;;
        "13d"|"13n") icon=""; quote="Snow" ;;
        *) icon=""; quote="Unknown" ;;
    esac
    echo "$icon|$quote"
}

get_hex() {
    case $1 in
        "50d"|"50n") echo "#84afdb" ;;
        "01d") echo "#f9e2af" ;;
        "01n") echo "#cba6f7" ;;
        "02d"|"02n"|"03d"|"03n"|"04d"|"04n") echo "#bac2de" ;;
        "09d"|"09n"|"10d"|"10n") echo "#74c7ec" ;;
        "11d"|"11n") echo "#f9e2af" ;;
        "13d"|"13n") echo "#cdd6f4" ;;
        *) echo "#cdd6f4" ;;
    esac
}

write_dummy_data() {
    final_json="["
    for i in {0..4}; do
        future_date=$(date -d "+$i days")
        f_day=$(date -d "$future_date" "+%a")
        f_full_day=$(date -d "$future_date" "+%A")
        f_date_num=$(date -d "$future_date" "+%d %b")
        
        final_json="${final_json} {
            \"id\": \"${i}\",
            \"day\": \"${f_day}\",
            \"day_full\": \"${f_full_day}\",
            \"date\": \"${f_date_num}\",
            \"max\": \"0.0\",
            \"min\": \"0.0\",
            \"feels_like\": \"0.0\",
            \"wind\": \"0\",
            \"humidity\": \"0\",
            \"pop\": \"0\",
            \"icon\": \"\",
            \"hex\": \"#cdd6f4\",
            \"desc\": \"No API Key\",
            \"hourly\": [{\"time\": \"00:00\", \"temp\": \"0.0\", \"icon\": \"\", \"hex\": \"#cdd6f4\"}]
        },"
    done
    final_json="${final_json%,}]"
    echo "{ \"current_temp\": \"0.0\", \"current_icon\": \"\", \"current_hex\": \"#cdd6f4\", \"forecast\": ${final_json} }" > "${json_file}"
}

get_data() {
    # ---------------------------------------------------------
    # DUMMY DATA FALLBACK (If API key is missing or skipped)
    # ---------------------------------------------------------
    if [[ -z "$KEY" || "$KEY" == "Skipped" || "$KEY" == "OPENWEATHER_KEY" ]]; then
        write_dummy_data
        return
    fi

    # ---------------------------------------------------------
    # STANDARD API FETCH LOGIC
    # ---------------------------------------------------------
    # https: the API key rides in the query string — plain http sent it in
    # cleartext to anyone on the path.
    forecast_url="https://api.openweathermap.org/data/2.5/forecast?APPID=${KEY}&id=${ID}&units=${UNIT}"
    raw_api=$(curl -sf --max-time 15 "$forecast_url")

    weather_url="https://api.openweathermap.org/data/2.5/weather?APPID=${KEY}&id=${ID}&units=${UNIT}"
    raw_weather=$(curl -sf --max-time 15 "$weather_url")
    
    # Check if curl failed OR if OpenWeather returned an error
    api_cod=$(echo "$raw_api" | jq -r '.cod' 2>/dev/null)
    
    if [ -z "$raw_api" ] || [ -z "$raw_weather" ] || [[ "$api_cod" != "200" ]]; then
        # If curl failed (network glitch, rate limit, API downtime), don't destroy
        # the existing working cache. Just abort the update.
        # If there is NO cache at all, then fall back to dummy data.
        if [ ! -f "$json_file" ]; then
            write_dummy_data
        fi
        return
    fi

    # Parse LIVE current weather conditions to bypass UTC boundary issues
    c_temp=$(echo "$raw_weather" | jq -r '.main.temp')
    c_temp=$(printf "%.1f" "$c_temp")
    c_code=$(echo "$raw_weather" | jq -r '.weather[0].icon')
    c_icon=$(get_icon "$c_code" | cut -d'|' -f1)
    c_hex=$(get_hex "$c_code")

    current_date=$(date +%Y-%m-%d)
    tomorrow_date=$(date -d "tomorrow" +%Y-%m-%d)

    # NOTE: all day-bucketing below groups slots by the LOCAL date of each
    # slot's epoch (.dt | strflocaltime). The API's dt_txt is UTC — grouping on
    # it filed the local evening slots (17:00/20:00/23:00 in a UTC-negative
    # zone) under the NEXT day, so "today" lost its second half.

    # 1. ROLLOVER CHECK
    if [ -f "$next_day_cache_file" ]; then
        precache_date=$(jq -r '.[0].dt | strflocaltime("%Y-%m-%d")' "$next_day_cache_file" 2>/dev/null)
        if [ "$precache_date" == "$current_date" ]; then
            mv "$next_day_cache_file" "$daily_cache_file"
        fi
    fi

    # 2. PROCESS TODAY
    api_today_items=$(echo "$raw_api" | jq -c --arg d "$current_date" '.list[] | select((.dt | strflocaltime("%Y-%m-%d")) == $d)' | jq -s '.')

    if [ -f "$daily_cache_file" ]; then
        cached_date=$(jq -r '.[0].dt | strflocaltime("%Y-%m-%d")' "$daily_cache_file" 2>/dev/null)
        if [ "$cached_date" == "$current_date" ]; then
            merged_today=$(echo "$api_today_items" | jq --slurpfile cache "$daily_cache_file" \
                '($cache[0] + .) | unique_by(.dt) | sort_by(.dt)')
        else
            merged_today="$api_today_items"
        fi
    else
        merged_today="$api_today_items"
    fi

    echo "$merged_today" > "$daily_cache_file"

    # 3. PRE-CACHE TOMORROW
    api_tomorrow_items=$(echo "$raw_api" | jq -c --arg d "$tomorrow_date" '.list[] | select((.dt | strflocaltime("%Y-%m-%d")) == $d)' | jq -s '.')
    echo "$api_tomorrow_items" > "$next_day_cache_file"

    # 4. BUILD FINAL JSON
    processed_forecast=$(echo "$raw_api" | jq --argjson today "$merged_today" --arg date "$current_date" \
        '.list = ($today + [.list[] | select((.dt | strflocaltime("%Y-%m-%d")) != $date)])')

    if [ ! -z "$processed_forecast" ]; then
        dates=$(echo "$processed_forecast" | jq -r '.list[].dt | strflocaltime("%Y-%m-%d")' | uniq | head -n 5)
        
        final_json="["
        counter=0
        
        for d in $dates; do
            day_data=$(echo "$processed_forecast" | jq --arg d "$d" '[.list[] | select((.dt | strflocaltime("%Y-%m-%d")) == $d)]')

            raw_max=$(echo "$day_data" | jq '[.[].main.temp_max] | max')
            f_max_temp=$(printf "%.1f" "$raw_max")

            raw_min=$(echo "$day_data" | jq '[.[].main.temp_min] | min')
            f_min_temp=$(printf "%.1f" "$raw_min")

            raw_feels=$(echo "$day_data" | jq '[.[].main.feels_like] | max')
            f_feels_like=$(printf "%.1f" "$raw_feels")

            f_pop=$(echo "$day_data" | jq '[.[].pop] | max')
            f_pop_pct=$(echo "$f_pop * 100" | bc | cut -d. -f1)
            f_wind=$(echo "$day_data" | jq '[.[].wind.speed] | max | round')
            f_hum=$(echo "$day_data" | jq '[.[].main.humidity] | add / length | round')
            
            f_code=$(echo "$day_data" | jq -r '.[length/2 | floor].weather[0].icon')
            f_desc=$(echo "$day_data" | jq -r '.[length/2 | floor].weather[0].description' | sed -e "s/\b\(.\)/\u\1/g")
            # The description is free text from the network interpolated into a
            # hand-built JSON document — escape backslashes and quotes so a
            # crafted API response can't inject fields or break the JSON.
            f_desc=${f_desc//\\/\\\\}; f_desc=${f_desc//\"/\\\"}
            f_icon_data=$(get_icon "$f_code")
            f_icon=$(echo "$f_icon_data" | cut -d'|' -f1)
            f_hex=$(get_hex "$f_code")
            
            f_day=$(date -d "$d" "+%a")
            f_full_day=$(date -d "$d" "+%A")
            f_date_num=$(date -d "$d" "+%d %b")

            hourly_json="["
            count_slots=$(echo "$day_data" | jq '. | length')
            count_slots=$((count_slots-1))
            
            for i in $(seq 0 1 $count_slots); do
                slot_item=$(echo "$day_data" | jq ".[$i]")
                
                raw_s_temp=$(echo "$slot_item" | jq ".main.temp")
                s_temp=$(printf "%.1f" "$raw_s_temp")
                
                s_dt=$(echo "$slot_item" | jq ".dt")
                s_time=$(date -d @$s_dt "+%H:%M")
                s_code=$(echo "$slot_item" | jq -r ".weather[0].icon")
                s_hex=$(get_hex "$s_code")
                s_icon=$(get_icon "$s_code" | cut -d'|' -f1)
                
                hourly_json="${hourly_json} {\"time\": \"${s_time}\", \"temp\": \"${s_temp}\", \"icon\": \"${s_icon}\", \"hex\": \"${s_hex}\"},"
            done
            hourly_json="${hourly_json%,}]"

            final_json="${final_json} {
                \"id\": \"${counter}\",
                \"day\": \"${f_day}\",
                \"day_full\": \"${f_full_day}\",
                \"date\": \"${f_date_num}\",
                \"max\": \"${f_max_temp}\",
                \"min\": \"${f_min_temp}\",
                \"feels_like\": \"${f_feels_like}\",
                \"wind\": \"${f_wind}\",
                \"humidity\": \"${f_hum}\",
                \"pop\": \"${f_pop_pct}\",
                \"icon\": \"${f_icon}\",
                \"hex\": \"${f_hex}\",
                \"desc\": \"${f_desc}\",
                \"hourly\": ${hourly_json}
            },"
            ((counter++))
        done
        final_json="${final_json%,}]"

        echo "{ \"current_temp\": \"${c_temp}\", \"current_icon\": \"${c_icon}\", \"current_hex\": \"${c_hex}\", \"forecast\": ${final_json} }" > "${json_file}"
    fi
}

# --- MODE HANDLING ---
if [[ "$1" == "--getdata" ]]; then
    get_data

elif [[ "$1" == "--json" ]]; then
    CACHE_LIMIT=900         # 15 minutes for valid working data
    PENDING_RETRY_LIMIT=3600 # 1 hour for invalid/activating keys

    if [ -f "$json_file" ]; then
        file_time=$(stat -c %Y "$json_file")
        current_time=$(date +%s)
        diff=$((current_time - file_time))
        
        if grep -q '"desc": "No API Key"' "$json_file"; then
            # Key is pending/invalid. Check once an hour.
            if [ $diff -gt $PENDING_RETRY_LIMIT ]; then
                touch "$json_file" # Bump file timestamp slightly to avoid spamming processes
                get_data &
            fi
        else
            # Normal working API key. Check every 15 mins.
            if [ $diff -gt $CACHE_LIMIT ]; then
                touch "$json_file"
                get_data &
            fi
        fi
        cat "$json_file"
    else
        get_data
        cat "$json_file"
    fi

elif [[ "$1" == "--view-listener" ]]; then
    if [ ! -f "$view_file" ]; then echo "0" > "$view_file"; fi
    tail -F "$view_file"

elif [[ "$1" == "--nav" ]]; then
    if [ ! -f "$view_file" ]; then echo "0" > "$view_file"; fi
    current=$(cat "$view_file")
    direction=$2
    max_idx=4
    if [[ "$direction" == "next" ]]; then
        if [ "$current" -lt "$max_idx" ]; then
            new=$((current + 1))
            echo "$new" > "$view_file"
        fi
    elif [[ "$direction" == "prev" ]]; then
        if [ "$current" -gt 0 ]; then
            new=$((current - 1))
            echo "$new" > "$view_file"
        fi
    fi

elif [[ "$1" == "--icon" ]]; then
    cat "$json_file" | jq -r '.forecast[0].icon'

elif [[ "$1" == "--temp" ]]; then 
    t=$(cat "$json_file" | jq -r '.forecast[0].max')
    echo "${t}${UNIT_SYM}"

elif [[ "$1" == "--hex" ]]; then 
    cat "$json_file" | jq -r '.forecast[0].hex'

elif [[ "$1" == "--current-icon" ]]; then
    icon=$(cat "$json_file" | jq -r '.current_icon // empty')
    if [[ -z "$icon" || "$icon" == "null" ]]; then 
        get_data
        icon=$(cat "$json_file" | jq -r '.current_icon')
    fi
    echo "$icon"

elif [[ "$1" == "--current-temp" ]]; then 
    t=$(cat "$json_file" | jq -r '.current_temp // empty')
    if [[ -z "$t" || "$t" == "null" ]]; then 
        get_data
        t=$(cat "$json_file" | jq -r '.current_temp')
    fi
    echo "${t}${UNIT_SYM}"

elif [[ "$1" == "--current-hex" ]]; then
    hex=$(cat "$json_file" | jq -r '.current_hex // empty')
    if [[ -z "$hex" || "$hex" == "null" ]]; then
        get_data
        hex=$(cat "$json_file" | jq -r '.current_hex')
    fi
    echo "$hex"

elif [[ "$1" == "--fetch" ]]; then
    # Foreground refresh driven by the topbar's 10-minute timer. Runs get_data INLINE
    # (curl is foreground + --max-time'd, nothing is backgrounded) so the process exits
    # the instant the fetch finishes — nothing is left lingering. Gated two ways so the
    # 3 per-monitor timers can't pile up: an atomic mkdir lock serialises concurrent
    # callers, and a cache-age check skips work unless the data is actually ~10 min old.
    # $2 overrides the cache-age threshold. The 10-min timer uses the 540s default; the
    # topbar's once-per-launch refresh passes a small value (e.g. 30) to force an update
    # on every reload/login while the lock+age check still stops the 3 monitors from all
    # fetching (the winner writes, the others see a fresh cache and skip).
    REFRESH_LIMIT="${2:-540}"        # < 600 so a 10-min timer never just-misses the window
    lock="${cache_dir}/.fetch.lock"
    if ! mkdir "$lock" 2>/dev/null; then
        # Steal a lock abandoned by a killed fetch (>120s old); otherwise stand down.
        if [ -d "$lock" ] && [ $(( $(date +%s) - $(stat -c %Y "$lock") )) -gt 120 ]; then
            rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || exit 0
        else
            exit 0
        fi
    fi
    trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
    if [ -f "$json_file" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$json_file") ))
        [ "$age" -ge "$REFRESH_LIMIT" ] && get_data
    else
        get_data
    fi

elif [[ "$1" == "--current-ro" ]]; then
    # READ-ONLY current values (icon / temp / hex on 3 lines) for the topbar poller.
    # NEVER fetches or writes. The --current-icon/temp/hex paths above call get_data
    # whenever current_* is empty (which is permanent with no API key) and get_data
    # REWRITES weather.json — together with the topbar's cache watcher that becomes a
    # fork-storm feedback loop (poll → write → watcher fires → poll → ...). Reading
    # only breaks the loop; the calendar's rate-limited --json is what repopulates.
    if [ -f "$json_file" ]; then
        icon=$(jq -r '.current_icon // ""'   "$json_file" 2>/dev/null)
        temp=$(jq -r '.current_temp // "--"' "$json_file" 2>/dev/null)
        hex=$( jq -r '.current_hex // ""'    "$json_file" 2>/dev/null)
        printf '%s\n%s%s\n%s\n' "$icon" "$temp" "$UNIT_SYM" "$hex"
    else
        printf '\n--\n\n'
    fi
fi
