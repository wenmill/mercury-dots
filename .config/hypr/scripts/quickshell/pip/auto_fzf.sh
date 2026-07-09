#!/usr/bin/env bash
#
# Non-interactive `fzf` replacement for headless ani-cli / lobster / lobster.
#
# Reads candidate lines on stdin, prints exactly ONE selection, exits. All real
# fzf CLI flags are ignored EXCEPT `--expect` (see below). Behaviour:
#   - If the list looks like a post-playback menu (next/replay/quit/exit/…),
#     print nothing → the CLI treats it as "escape/quit" and exits cleanly.
#   - Otherwise auto-pick the FIRST candidate (top search result / first quality).
#
# --expect handling (lobster): lobster calls `fzf --expect=shift-left` for its
# back-button, so it expects fzf to print an EXTRA first line = the key pressed
# (empty when the user just accepted). When `--expect` is among the args we emit
# a leading blank line (= "accepted, no special key") so lobster's parser strips
# it and reads our candidate as the selection. lobster / ani-cli never pass
# --expect, so their single-line behaviour is unchanged.
#
# This lets the CLI resolve a stream link and hand it to the PiP without ever
# blocking on a user prompt.
input="$(cat)"

# Does the caller use fzf --expect (lobster)? Then a blank key line must lead.
expect=""
for a in "$@"; do
    case "$a" in --expect|--expect=*|-expect|-expect=*) expect=1 ;; esac
done

[ -z "$input" ] && { [ -n "$expect" ] && printf '\n'; exit 0; }

low="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
case "$low" in
    *next\ episode*|*replay\ episode*|*previous\ episode*|*next\ ep*|*replay\ ep*|*quit*|*exit*)
        # post-play menu → stop the loop. Under --expect (lobster) pick "Exit" so
        # its continue-prompt ends cleanly; otherwise emit nothing (lobster/ani-cli).
        [ -n "$expect" ] && printf '\nExit\n'
        exit 0 ;;
esac

[ -n "$expect" ] && printf '\n'          # blank --expect key line (Enter/accept)
printf '%s\n' "$input" | head -n1
