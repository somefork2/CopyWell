#!/bin/bash
# shoot.sh <frame number> [language] — renders one 2880x1800 store shot from shots.html.
#
# Headless Chrome at 2x is the whole trick: the scene is ordinary HTML, so the
# copy can be edited and re-rendered in seconds, and the output lands at exactly
# the size the Mac App Store asks for.
set -e
here=$(cd "$(dirname "$0")" && pwd)
lang="${2:-en}"
out="$here/out/$lang/$1.png"
mkdir -p "$here/out/$lang"
rm -f "$out"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1440,900 --allow-file-access-from-files --virtual-time-budget=4000 \
  --user-data-dir="$here/.chrome-$lang-$1" \
  --screenshot="$out" "file://$here/shots.html?n=$1&lang=$lang" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 40); do [ -s "$out" ] && sleep 1 && break; sleep 0.5; done
kill -9 $pid 2>/dev/null || true
# Helpers outlive the main process when it is killed hard; take them too.
pkill -9 -f -- "--user-data-dir=$here/.chrome-$lang-$1" 2>/dev/null || true
rm -rf "$here/.chrome-$lang-$1" 2>/dev/null || true
[ -s "$out" ] || { echo "frame $1 did not render" >&2; exit 1; }
echo "$out"
