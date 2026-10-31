#!/bin/sh
# usage: grab_eye.sh name  -> logs/<name>.png in the repo folder (left eye, 1/3 size)
root=$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd)); mkdir -p "$root/logs"
d="$APPDATA/UnrealVRMod/GoWEDay-Steam"; rm -f "$d/dump_eye.dds"; touch "$d/dump_request"
for i in $(seq 1 20); do [ -f "$d/dump_eye.dds" ] && [ ! -f "$d/dump_request" ] && break; sleep 0.5; done; sleep 1
py -3 -I "$root/tools/dds2png.py" "$d/dump_eye.dds" "$root/logs/grip_full.png" 1 >/dev/null
py -3 -I -c "
from PIL import Image
Image.open('$root/logs/grip_full.png').crop((0, 0, 2244, 2352)).resize((748, 784)).save('$root/logs/$1.png')"
