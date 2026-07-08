#!/usr/bin/env bash
#
# Search YouTube via yt-dlp and emit one TSV line per result:
#     <videoId>\t<title>\t<channel>\t<duration_seconds>
#
# Used by the movies widget's YouTube tab to fill a thumbnail grid. Thumbnails
# are derived in QML from the id (https://i.ytimg.com/vi/<id>/mqdefault.jpg) and
# clicking a result plays https://youtube.com/watch?v=<id> into the mpv PiP.
#
# --flat-playlist keeps it fast (no per-video format resolution). If yt-dlp is
# missing we emit a sentinel so the UI can show an install hint.
#
q="$*"
[ -z "$q" ] && exit 0

if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "__NOYTDLP__"
    exit 0
fi

exec yt-dlp --flat-playlist --no-warnings --ignore-errors \
    --print $'%(id)s\t%(title)s\t%(channel)s\t%(duration)s' \
    "ytsearch24:$q"
