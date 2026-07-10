#!/usr/bin/env bash
# Repair podman's overlay storage after its short-name symlinks go missing.
#
# Symptom: every container fails to start or build, and `podman system check`
# reports dozens or hundreds of
#     Damaged layer <id>: readlink .../overlay/l/XXXXXXXX: no such file or directory
#
# Cause: podman keeps each layer's data in overlay/<layerid>/diff and points at
# it through a short symlink overlay/l/<SHORT>, because a mount option built
# from full layer IDs would exceed the kernel's page-size limit. If the contents
# of overlay/l/ are lost — a tmp cleaner, an interrupted filesystem operation,
# an aborted `podman system reset` — every layer reads as damaged even though no
# layer data is gone.
#
# Recovery: each layer directory contains a `link` file naming its own short
# symlink, so the whole mapping is reconstructible from data already on disk.
#
# Do NOT reach for `podman system check --repair` here. It *deletes* damaged
# layers, which on a store where every layer is "damaged" means deleting every
# image you have. Volumes survive that, images do not.
#
# This script only ever CREATES symlinks. It never deletes or overwrites one,
# and it reports any that already exist pointing somewhere else rather than
# silently replacing them.
#
#   podman_relink.sh --dry-run   count what is missing; change nothing
#   podman_relink.sh             create the missing symlinks
#
# Afterwards: `podman system check` should report zero damaged layers, and
# `podman-compose -p <project> up -d` should work again. Stop podman-using
# services first if any are mid-operation; the storage lock is per-command, so
# a running container is not a problem, but a running build is.
set -uo pipefail

O="${CONTAINERS_STORAGE_OVERLAY:-$HOME/.local/share/containers/storage/overlay}"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY=1

[ -d "$O" ] || { echo "error: no overlay store at $O" >&2; exit 1; }
[ -d "$O/l" ] || mkdir -p "$O/l"

made=0 skipped=0 nolink=0 nodiff=0 conflict=0

for d in "$O"/*/; do
    id="$(basename "$d")"
    # `l` holds the symlinks themselves; `tempdirs` is podman scratch. Neither
    # is a layer.
    [ "$id" = "l" ] && continue
    [ "$id" = "tempdirs" ] && continue

    [ -f "$d/link" ] || { nolink=$((nolink + 1)); continue; }
    l="$(cat "$d/link" 2>/dev/null)"
    [ -n "$l" ] || { nolink=$((nolink + 1)); continue; }
    [ -d "$d/diff" ] || { nodiff=$((nodiff + 1)); continue; }

    tgt="../$id/diff"
    if [ -L "$O/l/$l" ]; then
        cur="$(readlink "$O/l/$l")"
        if [ "$cur" = "$tgt" ]; then
            skipped=$((skipped + 1))
        else
            conflict=$((conflict + 1))
            echo "CONFLICT: l/$l -> $cur (expected $tgt) — left untouched" >&2
        fi
        continue
    fi

    if [ -n "$DRY" ]; then
        made=$((made + 1))
    else
        ln -s "$tgt" "$O/l/$l" && made=$((made + 1))
    fi
done

if [ -n "$DRY" ]; then
    echo "would create: $made   already correct: $skipped   no link file: $nolink   no diff dir: $nodiff   conflicts: $conflict"
    echo "(nothing was changed)"
else
    echo "created: $made   already correct: $skipped   no link file: $nolink   no diff dir: $nodiff   conflicts: $conflict"
    echo "Verify with: podman system check"
fi

[ "$conflict" -eq 0 ] || exit 1
