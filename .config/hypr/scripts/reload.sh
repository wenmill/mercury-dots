#!/usr/bin/env bash
# Reload the Quickshell bar with a CLEAN SLATE.
#
# The old reload used an in-place `ipc call main forceReload`, which tears down the
# QML engine's Process objects (the `bash` wrappers) but leaves their pipeline
# grandchildren — inotifywait / dbus-monitor / socat — orphaned and reparented to
# `systemd --user`, where they run forever. Over many reloads these pile up
# (hundreds of MB of dead watchers).
#
# Strategy: kill the bar FIRST so it can't respawn watchers mid-teardown, then sweep
# its now-orphaned watcher subprocesses, matched by precise command signatures so no
# unrelated process is ever touched, then relaunch fresh.
QML="$HOME/.config/hypr/scripts/quickshell/Shell.qml"

# 1) Kill the running bar(s) first (cmdline ends in Shell.qml — excludes ipc clients).
for p in $(pgrep -f 'Shell\.qml$' 2>/dev/null); do kill "$p" 2>/dev/null; done
# Wait up to ~2s for a clean exit, then force.
for _ in $(seq 1 20); do pgrep -f 'Shell\.qml$' >/dev/null || break; sleep 0.1; done
pgrep -f 'Shell\.qml$' >/dev/null && pkill -9 -f 'Shell\.qml$'

# 2) Sweep the bar's watcher subprocesses (now orphaned), matched by signature.
pkill -f 'inotifywait.*(\.config/hypr|\.cache/qs_)'                                 2>/dev/null
pkill -f 'dbus-monitor.*(org\.mpris\.MediaPlayer2|org\.freedesktop\.Notifications|org\.bluez)' 2>/dev/null
pkill -f 'socat.*hypr.*socket2\.sock'                                               2>/dev/null
pkill -f 'scripts/quickshell/watchers/.*_wait\.sh'                                  2>/dev/null

# 3) Relaunch fresh.
# Point at the locally-built PipMpv module (now under pip/qml) so the embedded
# mpv player resolves even before the env.conf change takes effect on next login.
sleep 0.3
QML_IMPORT_PATH="$HOME/.config/hypr/scripts/quickshell/pip/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" quickshell -p "$QML" >/dev/null 2>&1 &
disown

# 4) Also reload the obsidian-shell floating panel. It's a SEPARATE compiled
#    process that reads its QML/JS (and injected transparency scripts) once at
#    startup, so the Quickshell reload above never updates it. Its own `restart`
#    handles the kill + wait + relaunch to the idle edge-peek state (not popped
#    open). Done unconditionally so a bar reload always refreshes the panel — and
#    starts it if it wasn't running.
SPIKE_SH="$HOME/.config/hypr/scripts/quickshell/floating/obsidian-shell.sh"
bash "$SPIKE_SH" restart >/dev/null 2>&1 &
disown

# 5) The dbus-monitor sweep above (org.bluez) also kills controller_gaming_watch.sh,
#    which is otherwise only spawned at boot. Respawn it here; its singleton guard
#    makes this a no-op-safe operation (never duplicates).
setsid bash "$HOME/.config/hypr/scripts/quickshell/watchers/controller_gaming_watch.sh" >/dev/null 2>&1 < /dev/null &
disown

# 6) The inotifywait sweep (step 2) also kills settings_watcher.sh's monitor pipe,
#    which ends its read loop and exits the whole watcher — leaving settings.json
#    edits silently un-compiled until reboot. Respawn it (singleton-guarded too).
setsid bash "$HOME/.config/hypr/scripts/settings_watcher.sh" >/dev/null 2>&1 < /dev/null &
disown
