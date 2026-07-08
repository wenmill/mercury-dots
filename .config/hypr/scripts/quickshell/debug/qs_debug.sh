#!/usr/bin/env bash
# =============================================================================
# qs_debug.sh — per-widget memory / CPU profiler for the Quickshell desktop
# =============================================================================
# IMPORTANT — read this once:
#   Every QML widget (TopBar, BatteryPopup, NetworkPopup, AiPopup, …) runs inside
#   ONE process: `quickshell -p Shell.qml`. The kernel only accounts memory & CPU
#   per *process/thread*, never per QML subtree — so there is no /proc entry for an
#   individual .qml. This tool gets per-widget numbers the only honest way it can:
#
#     • MEMORY  → the *incremental RSS* the process gains the first time a widget is
#                 created. Widgets are lazily built + cached (Main.qml), so opening
#                 one for the first time makes the process grow by ~that widget's
#                 footprint. We open them one-by-one and diff RSS between steps.
#                 (A widget already preloaded at startup shows ~0 — it's flagged.)
#
#     • CPU     → the process-wide CPU% while a given widget is the visible one,
#                 minus the idle baseline (TopBar only). That isolates the steady
#                 cost a widget imposes via its bindings/animations/timers/pollers.
#
# Modes:
#   qs_debug.sh live   [interval]      Non-intrusive. Whole-process PSS/RSS + CPU%,
#                                      with a per-THREAD CPU breakdown (render/GC/IO).
#   qs_debug.sh profile [cpu_secs]     Intrusive. Cycles every widget on screen and
#                                      prints a ranked memory + CPU table. Logs to file.
#   qs_debug.sh watch  <widget> [iv]   Open one widget and sample the process live so
#                                      you can interact with it and watch CPU move.
#
# Examples:  qs_debug.sh live          qs_debug.sh profile 3
#            qs_debug.sh watch calendar
# =============================================================================
set -u

SCRIPTS_DIR="$HOME/.config/hypr/scripts/quickshell"
MANAGER="$HOME/.config/hypr/scripts/qs_manager.sh"
LOG_DIR="${XDG_RUNTIME_DIR:-/tmp}/quickshell/logs"
mkdir -p "$LOG_DIR"

CLK=$(getconf CLK_TCK); CLK=${CLK:-100}
NCPU=$(nproc)

# Widget list — mirrors WindowRegistry.js getLayout(). `hidden` (no comp) is
# intentionally excluded. (Stewart was removed; Athena is a Hermes voice trigger,
# not a popup — see scripts/athena.sh, bound to Super+G.)
WIDGETS=(battery network volume library matrix music applauncher tools \
         clipboard focustime guide calendar wallpaper movies settings)

# --- colors (no-op if not a tty) ---
if [ -t 1 ]; then
    B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; MAG=$'\e[35m'
else
    B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""
fi

find_pid() { pgrep -f 'quickshell.*Shell.qml' | head -1; }

# RSS / PSS of a pid in kB (PSS = proportional set size, the fairest "real" cost).
read_rss() { awk '/^Rss:/{print $2; exit}' "/proc/$1/smaps_rollup" 2>/dev/null; }
read_pss() { awk '/^Pss:/{print $2; exit}' "/proc/$1/smaps_rollup" 2>/dev/null; }

# Busy jiffies (utime+stime) of a pid/tid. Parses /proc/.../stat AFTER the ")" so a
# comm containing spaces or parens can't shift the field positions.
read_busy() {
    local s r
    s=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
    r="${s#*) }"
    # shellcheck disable=SC2086
    set -- $r
    echo $(( ${12} + ${13} ))   # utime + stime
}

now() { date +%s.%N; }

# One awk pass over EVERY thread's stat file → "tid busy comm" lines (busy=utime+stime).
# A single fork for all ~40 threads; the alternative (cat/tr/awk per thread) is ~160
# forks per frame and made the monitor itself a CPU hog. comm is taken between the
# first "(" and last ")" so spaces/parens in a thread name can't shift fields.
snap_threads() {
    awk '{
        split(FILENAME,a,"/"); tid=a[5];
        lp=index($0,"("); rp=0;
        for(i=length($0);i>0;i--){ if(substr($0,i,1)==")"){rp=i;break} }
        comm=substr($0,lp+1,rp-lp-1);
        rest=substr($0,rp+2); split(rest,f," ");
        print tid, f[12]+f[13], comm;
    }' /proc/"$1"/task/*/stat 2>/dev/null
}

# CPU% (of a single core) between two busy-jiffy samples taken dt_wall seconds apart.
cpu_pct() { awk -v dj="$(( $2 - $1 ))" -v clk="$CLK" -v dt="$3" \
    'BEGIN{ if(dt<=0){print "0.0"} else printf "%.1f", 100*(dj/clk)/dt }'; }

close_all() { "$MANAGER" close >/dev/null 2>&1; }
open_widget() { "$MANAGER" open "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
mode_live() {
    local iv="${1:-2}" PID
    PID=$(find_pid); [ -z "$PID" ] && { echo "${RED}quickshell not running${R}"; exit 1; }
    echo "${DIM}Watching PID $PID — Ctrl-C to stop. Interval ${iv}s.${R}"

    declare -A prevT          # previous busy jiffies per tid
    local pBusy pT tid busy comm
    pBusy=$(read_busy "$PID"); pT=$(now)
    while read -r tid busy comm; do prevT[$tid]=$busy; done < <(snap_threads "$PID")
    sleep "$iv"

    while kill -0 "$PID" 2>/dev/null; do
        local cBusy cT dt dt_ms pct rss pss
        cBusy=$(read_busy "$PID"); cT=$(now)
        dt=$(awk -v a="$pT" -v b="$cT" 'BEGIN{printf "%.3f", b-a}')
        dt_ms=$(awk -v a="$pT" -v b="$cT" 'BEGIN{printf "%d", (b-a)*1000}'); (( dt_ms>0 )) || dt_ms=1
        pct=$(cpu_pct "$pBusy" "$cBusy" "$dt")
        rss=$(read_rss "$PID"); pss=$(read_pss "$PID")

        clear
        printf "%s╭─ Quickshell live ── PID %s ── %s ─╮%s\n" "$B$CYN" "$PID" "$(date +%H:%M:%S)" "$R"
        printf "  %sMemory%s  RSS %s%6.1f MB%s   PSS %s%6.1f MB%s\n" \
            "$B" "$R" "$GRN" "$(awk -v k="$rss" 'BEGIN{print k/1024}')" "$R" \
            "$YEL" "$(awk -v k="$pss" 'BEGIN{print k/1024}')" "$R"
        printf "  %sCPU%s     %s%5s%%%s of one core  %s(%.1f%% of %s-core total)%s\n" \
            "$B" "$R" "$MAG" "$pct" "$R" "$DIM" \
            "$(awk -v p="$pct" -v n="$NCPU" 'BEGIN{print p/n}')" "$NCPU" "$R"
        printf "  %s%-18s %8s%s\n" "$DIM" "thread" "cpu%/core" "$R"

        # Per-thread cpu over the same interval. Delta math is pure-bash integer (tenths
        # of a %) so no process is forked per thread; the here-string `< <(...)` keeps the
        # loop in THIS shell so prevT[] updates persist (a pipe would subshell it away).
        local lines="" prev dj tenths
        while read -r tid busy comm; do
            prev=${prevT[$tid]:-$busy}; prevT[$tid]=$busy
            dj=$(( busy - prev )); (( dj > 0 )) || continue
            tenths=$(( 1000000 * dj / (CLK * dt_ms) ))   # = 10 * cpu% of one core
            (( tenths >= 3 )) || continue                # hide < 0.3%
            lines+="$tenths	$comm"$'\n'
        done < <(snap_threads "$PID")
        printf '%s' "$lines" | sort -rn | head -8 | \
            while IFS=$'\t' read -r t c; do printf "  %-18s %6d.%d\n" "$c" $((t/10)) $((t%10)); done

        pBusy=$cBusy; pT=$cT
        sleep "$iv"
    done
}

# -----------------------------------------------------------------------------
mode_profile() {
    local cpu_secs="${1:-3}" PID ts log
    PID=$(find_pid); [ -z "$PID" ] && { echo "${RED}quickshell not running${R}"; exit 1; }
    ts=$(date +%Y%m%d-%H%M%S); log="$LOG_DIR/qs_profile-$ts.log"

    echo "${B}${CYN}Profiling ${#WIDGETS[@]} widgets — this opens each one on screen.${R}"
    echo "${DIM}PID $PID · CPU sample ${cpu_secs}s/widget · log → $log${R}"
    echo

    close_all; sleep 1.5
    local base_rss base_busy base_t base_cpu
    base_rss=$(read_rss "$PID")
    base_busy=$(read_busy "$PID"); base_t=$(now); sleep "$cpu_secs"
    base_cpu=$(cpu_pct "$base_busy" "$(read_busy "$PID")" \
               "$(awk -v a="$base_t" -v b="$(now)" 'BEGIN{print b-a}')")
    printf "%sidle baseline (TopBar only): RSS %.1f MB · CPU %s%%%s\n\n" \
        "$DIM" "$(awk -v k="$base_rss" 'BEGIN{print k/1024}')" "$base_cpu" "$R"

    # name|deltaMB|activeCPU|marginalCPU
    local rows=() prev_rss="$base_rss"
    printf "%s%-12s %10s %10s %12s%s\n" "$B" "widget" "ΔRSS(MB)" "CPU%" "marginal%" "$R"
    printf "%s%s%s\n" "$DIM" "------------------------------------------------" "$R"

    for w in "${WIDGETS[@]}"; do
        open_widget "$w"; sleep 1.3                    # let it create + first paint
        local rss dmb b1 t1 b2 t2 dt cpu marg
        rss=$(read_rss "$PID")
        dmb=$(awk -v a="$prev_rss" -v b="$rss" 'BEGIN{printf "%.1f",(b-a)/1024}')
        b1=$(read_busy "$PID"); t1=$(now); sleep "$cpu_secs"
        b2=$(read_busy "$PID"); t2=$(now)
        dt=$(awk -v a="$t1" -v b="$t2" 'BEGIN{print b-a}')
        cpu=$(cpu_pct "$b1" "$b2" "$dt")
        marg=$(awk -v c="$cpu" -v base="$base_cpu" 'BEGIN{m=c-base; if(m<0)m=0; printf "%.1f",m}')

        local flag=""
        awk -v d="$dmb" 'BEGIN{exit !(d<0.5)}' && flag=" ${DIM}(cached/preloaded)${R}"
        printf "%-12s %10s %10s %12s%s\n" "$w" "$dmb" "$cpu" "$marg" "$flag"
        rows+=("$w|$dmb|$cpu|$marg")
        prev_rss="$rss"
    done
    close_all

    {
        echo "# qs_debug profile $ts"
        echo "# idle baseline RSS=$(awk -v k="$base_rss" 'BEGIN{print k/1024}')MB CPU=${base_cpu}%"
        echo "widget|deltaRSS_MB|activeCPU_pct|marginalCPU_pct"
        printf '%s\n' "${rows[@]}"
    } > "$log"

    echo
    echo "${B}Top memory:${R}"
    printf '%s\n' "${rows[@]}" | sort -t'|' -k2 -rn | head -5 | \
        awk -F'|' -v g="$GRN" -v r="$R" '{printf "  %s%-12s %6s MB%s\n", g,$1,$2,r}'
    echo "${B}Top CPU (marginal):${R}"
    printf '%s\n' "${rows[@]}" | sort -t'|' -k4 -rn | head -5 | \
        awk -F'|' -v m="$MAG" -v r="$R" '{printf "  %s%-12s %6s%%%s\n", m,$1,$4,r}'
    echo "${DIM}Saved: $log${R}"
}

# -----------------------------------------------------------------------------
mode_watch() {
    local w="${1:-}" iv="${2:-1}" PID
    [ -z "$w" ] && { echo "usage: qs_debug.sh watch <widget> [interval]"; exit 1; }
    PID=$(find_pid); [ -z "$PID" ] && { echo "${RED}quickshell not running${R}"; exit 1; }
    open_widget "$w"
    echo "${DIM}Opened '$w'. Interact with it; Ctrl-C to stop.${R}"
    local pB pT; pB=$(read_busy "$PID"); pT=$(now); sleep "$iv"
    while kill -0 "$PID" 2>/dev/null; do
        local cB cT dt pct rss
        cB=$(read_busy "$PID"); cT=$(now)
        dt=$(awk -v a="$pT" -v b="$cT" 'BEGIN{print b-a}')
        pct=$(cpu_pct "$pB" "$cB" "$dt"); rss=$(read_rss "$PID")
        printf "\r  %s%-10s%s  RSS %s%6.1f MB%s  CPU %s%5s%%%s   " \
            "$B" "$w" "$R" "$GRN" "$(awk -v k="$rss" 'BEGIN{print k/1024}')" "$R" \
            "$MAG" "$pct" "$R"
        pB=$cB; pT=$cT; sleep "$iv"
    done
}

case "${1:-live}" in
    live)    mode_live    "${2:-2}" ;;
    profile) mode_profile "${2:-3}" ;;
    watch)   mode_watch   "${2:-}" "${3:-1}" ;;
    *) grep -E '^#( |=|!)' "$0" | sed 's/^# \{0,1\}//' | head -40 ;;
esac
