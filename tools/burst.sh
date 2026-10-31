#!/bin/sh
# usage: burst.sh name count  -> fast eye dumps, converted after: logs/<name>_<i>.png (left eye, 1/3 size)
root=$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd)); mkdir -p "$root/logs"
d="$APPDATA/UnrealVRMod/GoWEDay-Steam"; n=${2:-4}
for i in $(seq 1 $n); do
  rm -f "$d/dump_eye.dds"; touch "$d/dump_request"
  for k in $(seq 1 40); do [ -f "$d/dump_eye.dds" ] && [ ! -f "$d/dump_request" ] && break; sleep 0.1; done
  sleep 0.2; mv "$d/dump_eye.dds" "$TEMP/burst_$i.dds"
done
for i in $(seq 1 $n); do
  py -3 -I "$root/tools/dds2png.py" "$TEMP/burst_$i.dds" "$TEMP/burst_full.png" 1 >/dev/null
  py -3 -I -c "
from PIL import Image
Image.open(r'$TEMP/burst_full.png').crop((0, 0, 2244, 2352)).resize((748, 784)).save('$root/logs/$1_$i.png')"
done
