#!/bin/sh
# usage: dbg.sh 'lua code'   (or: dbg.sh -f file.lua)  -> runs it in the game via zz_debug.lua, prints debug/out.txt
d="$APPDATA/UnrealVRMod/GoWEDay-Steam/data"
rm -f "$d/dbg_out.txt"
if [ "$1" = "-f" ]; then cp "$2" "$d/dbg_cmd.tmp"; else printf '%s\n' "$1" > "$d/dbg_cmd.tmp"; fi
mv "$d/dbg_cmd.tmp" "$d/dbg_cmd.lua"
for i in $(seq 1 40); do [ -f "$d/dbg_out.txt" ] && break; sleep 0.25; done
if [ -f "$d/dbg_out.txt" ]; then cat "$d/dbg_out.txt"; else echo "no answer (game not running, or zz_debug.lua off)"; rm -f "$d/dbg_cmd.lua"; fi
