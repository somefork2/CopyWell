#!/bin/bash
# render-all.sh [language…] — renders the whole ten-frame listing for every
# language (or the ones given) into docs/screenshots/store/<language>/.
#
# Frames 02, 03, 05 and 06 come from a development build of the app
# (--render-feature-shots); the rest from shots.html through headless Chrome.
# Build the Debug configuration first so the app binary is current.
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
app="$repo/build/dd/Build/Products/Debug/CopyWell.app/Contents/MacOS/CopyWell"
container="$HOME/Library/Containers/com.copywell.app/Data/Documents"
store="$repo/docs/screenshots/store"

python3 "$here/make-strings.py" >/dev/null
mkdir -p "$container/shot-strings"
cp "$repo"/docs/store/shots/*.json "$container/shot-strings/"

if [ $# -gt 0 ]; then
  languages="$*"
else
  languages=$(cd "$repo/docs/store/shots" && ls *.json | sed 's/\.json$//' | tr '\n' ' ')
fi

for lang in $languages; do
  out="$store/$lang"
  mkdir -p "$out"

  # The app's four frames. It exits on its own when done.
  "$app" --render-feature-shots --language "$lang" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 120); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  kill $pid 2>/dev/null || true
  features="$container/Screenshots/features/$lang"

  # The five HTML frames, one at a time: two headless Chromes at once starve
  # each other and neither takes its screenshot. One retry each.
  for n in 1 2 3 4 5; do
    "$here/shoot.sh" $n "$lang" >/dev/null || "$here/shoot.sh" $n "$lang" >/dev/null
  done

  cp "$here/out/$lang/1.png"                     "$out/01-palette.png"
  cp "$features/feature-1-screenshots.png"       "$out/02-screenshots.png"
  cp "$features/feature-2-recording.png"         "$out/03-screen-recording.png"
  cp "$here/out/$lang/2.png"                     "$out/04-search.png"
  cp "$features/feature-3-choose.png"            "$out/05-record-anything.png"
  cp "$features/feature-4-recordings.png"        "$out/06-recordings.png"
  cp "$here/out/$lang/3.png"                     "$out/07-text-in-images.png"
  cp "$here/out/$lang/4.png"                     "$out/08-pinboards.png"
  cp "$here/out/$lang/5.png"                     "$out/09-privacy.png"
  rm -f "$out/10-right-click.png"
  echo "$lang: $(ls "$out" | wc -l | tr -d ' ') frames"
done
