#!/usr/bin/env bash
# ~/.config/hypr/scripts/focus_warning.sh
# Interactive notification 5 minutes before study timer ends
# Uses notify-send -A (libnotify 0.8+) for action buttons

CURRENT_END=$(cat ~/.cache/qs_focus_end 2>/dev/null || echo "0")
NOW=$(date +%s)
REMAIN=$((CURRENT_END - NOW))

if [ "$REMAIN" -le 0 ]; then
    exit 0
fi

MINS_LEFT=$((REMAIN / 60))

# Send notification with action buttons
# notify-send -A blocks and returns the clicked action key on stdout
ACTION=$(notify-send \
    -u critical \
    -i dialog-warning \
    -A "add15=+15 min" \
    -A "add30=+30 min" \
    -A "add60=+1 hour" \
    -A "stop=End now" \
    "Study Timer — ${MINS_LEFT} min left" \
    "Your study session ends soon. Need more time?")

# Read current end time fresh (it may have changed)
CURRENT_END=$(cat ~/.cache/qs_focus_end 2>/dev/null || echo "0")

case "$ACTION" in
    add15)
        echo $((CURRENT_END + 900)) > ~/.cache/qs_focus_end
        notify-send "Focus Mode" "Added 15 minutes"
        ;;
    add30)
        echo $((CURRENT_END + 1800)) > ~/.cache/qs_focus_end
        notify-send "Focus Mode" "Added 30 minutes"
        ;;
    add60)
        echo $((CURRENT_END + 3600)) > ~/.cache/qs_focus_end
        notify-send "Focus Mode" "Added 1 hour"
        ;;
    stop)
        echo "default" > ~/.cache/qs_focus_mode
        echo "0" > ~/.cache/qs_focus_end
        notify-send "Focus Mode" "Study session ended"
        ;;
esac
