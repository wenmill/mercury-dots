#!/usr/bin/env bash
#
# anime_epcount.sh <title> — AllAnime episode counts for the show that BEST
# matches <title>, per translation mode, plus each match's 1-based index in
# ani-cli's mode-filtered result list (so playback can select the SAME show
# with `ani-cli -S <idx>`):
#
#   {"sub": 87, "dub": 87, "name": "...", "subIdx": 3, "dubIdx": 2}
#
# The naive "first hit" was wrong constantly (e.g. "one piece" → "ONE PIECE
# HEROINES", 1 episode) — that both capped the episode list AND meant ani-cli
# -S 1 played the wrong show. Best-match + index fixes both at once.
set -uo pipefail
TITLE="${1:?title required}"

agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0"
refr="https://allmanga.to"
api="https://api.allanime.day/api"
gql='query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name englishName availableEpisodes __typename } }}'

fetch_mode() {   # <sub|dub> → raw JSON
    curl -e "$refr" -s -m 15 -H "Content-Type: application/json" -X POST "$api" \
        --data "{\"variables\":{\"search\":{\"allowAdult\":false,\"allowUnknown\":false,\"query\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$TITLE")},\"limit\":40,\"page\":1,\"translationType\":\"$1\",\"countryOrigin\":\"ALL\"},\"query\":\"$gql\"}" \
        -A "$agent" 2>/dev/null
}

SUB_JSON="$(fetch_mode sub)" DUB_JSON="$(fetch_mode dub)" TITLE="$TITLE" python3 <<'PY'
import os, json, re

def norm(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())

want = norm(os.environ["TITLE"])

def pick(raw, mode):
    """Best match among edges with ≥1 episode of `mode`, plus its 1-based
    index in that filtered list (== ani-cli's -S index for this mode)."""
    try:
        edges = json.loads(raw)["data"]["shows"]["edges"]
    except Exception:
        return 0, 0, ""
    filtered = [e for e in edges if (e.get("availableEpisodes") or {}).get(mode, 0) > 0]
    if not filtered:
        return 0, 0, ""
    def name_score(n):
        n = norm(n)
        if not n:               return 0
        if n == want:           return 100
        if n.startswith(want):  return 80 - min(30, len(n) - len(want))
        if want and want in n:  return 50 - min(30, len(n) - len(want))
        return 0
    best, best_idx, best_score = None, 0, -1
    for i, e in enumerate(filtered):
        # AllAnime names are Japanese; Kitsu hands us English — try both.
        score = max(name_score(e.get("name")), name_score(e.get("englishName")))
        if score > best_score:
            best, best_idx, best_score = e, i + 1, score
    counts = best.get("availableEpisodes") or {}
    return counts.get(mode, 0), best_idx, best.get("name", "")

sub, sub_idx, sname = pick(os.environ["SUB_JSON"], "sub")
dub, dub_idx, dname = pick(os.environ["DUB_JSON"], "dub")
print(json.dumps({"sub": sub, "dub": dub, "subIdx": sub_idx, "dubIdx": dub_idx,
                  "name": sname or dname}))
PY
