#!/usr/bin/env bash
# Render the game and look at it.
#
#   tools/shot.sh                               # the lobby, first person, flashlight on
#   tools/shot.sh --view=witch --level=8        # five metres from a witch, looking at her
#   tools/shot.sh --view=third --level=3        # third person
#   tools/shot.sh --view=above --level=16       # the whole level from above, lit
#   tools/shot.sh --level=2 --room=r3 --yaw=90  # standing in a room
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
args=(); view="eyes"; out=""
for arg in "$@"; do
    case "$arg" in
        --view=*) view="${arg#*=}"; args+=("$arg") ;;
        --out=*) out="${arg#*=}" ;;
        *) args+=("$arg") ;;
    esac
done
[ -n "$out" ] || out="res://screenshots/${view}.png"
exec xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 res://tools/shot.tscn -- "--out=$out" "--view=$view" "${args[@]}"
