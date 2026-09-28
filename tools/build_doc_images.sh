#!/usr/bin/env bash
# Builds the doc images from in-game frames captured by `test/run.sh shots` (copied to build/shots-raw/).
#   docs/cybertruck-builds.png  every build, plus the glovebox cologne, in a captioned 3x2 grid
#   docs/cybertruck-musk.png    a spritz with the dead walking off, tooltip inset
# Needs ImageMagick 7 and the Noto Sans fonts.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RAW=$ROOT/build/shots-raw
OUT=$ROOT/docs
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BOLD=/usr/share/fonts/noto/NotoSans-Bold.ttf
REG=/usr/share/fonts/noto/NotoSans-Regular.ttf
BG='#0d0d0f'
ACCENT='#f07b1d'
W=600 H=375 CAP=70
# Screenshots come in at 16 bits a channel; 8-bit, 256 colors keeps them under a megabyte for the Workshop page.
SMALL="-depth 8 -dither FloydSteinberg -colors 256 -define png:compression-level=9"

# Tooltip: the in-game box, cut tight. The rig draws it solid black with the stock grey border, so
# find the box by that border instead of trusting where it landed on screen.
read -r TX TY TW TH < <(python3 - "$RAW/shot-musk-tooltip.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
px = im.load()
def grey(x, y):
    r, g, b = px[x, y]
    return r == g == b and abs(r - 102) <= 2
# The box edge is the only long straight run of that grey; asphalt only has scattered pixels of it.
def longest(cells):
    best, start, run_start, run = (0, 0, 0), None, 0, 0
    for i, on in enumerate(cells):
        if on:
            if run == 0: run_start = i
            run += 1
            if run > best[0]: best = (run, run_start, i)
        else:
            run = 0
    return best
rows = sorted(((longest([grey(x, y) for x in range(w)]), y) for y in range(h)), reverse=True)[:2]
(top_run, y0), (bot_run, y1) = sorted(rows, key=lambda r: r[1])
x0, x1 = top_run[1], top_run[2]
print(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
PY
)
magick "$RAW/shot-musk-tooltip.png" -alpha off -crop ${TW}x${TH}+${TX}+${TY} +repage "$TMP/tooltip.png"

tile() { # src title subtitle out
    magick "$1" -alpha off -resize ${W}x${H}^ -gravity center -extent ${W}x${H} \
        \( -size ${W}x${CAP} xc:"$BG" \
           -fill "$ACCENT" -draw "rectangle 0,0 5,${CAP}" \
           -font "$BOLD" -pointsize 24 -fill white -gravity northwest -annotate +20+8 "$2" \
           -font "$REG" -pointsize 17 -fill '#a8a8ad' -annotate +20+40 "$3" \) \
        -append "$4"
}

crop() { magick "$1" -alpha off -gravity center -crop 1400x875+0+0 +repage "$2"; }
for n in 1-bare 2-blades 3-hatch 4-gun 5-full; do crop "$RAW/shot-build-$n.png" "$TMP/$n.png"; done
# The cologne tile: the tooltip on the dark stage, sized like a portrait.
magick -size 1400x875 xc:"$BG" \( "$TMP/tooltip.png" -filter point -resize 300% \) -gravity center -composite "$TMP/6-musk.png"

tile "$TMP/1-bare.png"   "Stock"             "Stainless, armored glass, near-silent" "$TMP/t1.png"
tile "$TMP/2-blades.png" "Blade kit"         "Shreds the dead and fells trees"       "$TMP/t2.png"
tile "$TMP/3-hatch.png"  "Roof hatch"        "The gun mounts here"                   "$TMP/t3.png"
tile "$TMP/4-gun.png"    "Hatch + roof gun"  "Point, hold, fire 5.56"                "$TMP/t4.png"
tile "$TMP/5-full.png"   "Full kit"          "Everything bolted on"                  "$TMP/t5.png"
tile "$TMP/6-musk.png"   "Elon's Musk"       "In every glovebox. Zombies hate it."   "$TMP/t6.png"

magick -background "$BG" \( "$TMP/t1.png" "$TMP/t2.png" "$TMP/t3.png" +smush 12 \) \
       \( "$TMP/t4.png" "$TMP/t5.png" "$TMP/t6.png" +smush 12 \) \
       -smush 12 -bordercolor "$BG" -border 12 -strip $SMALL "PNG8:$OUT/cybertruck-builds.png"

# The spritz: the scene around the player, tooltip inset top right over the grass.
magick "$RAW/shot-musk-repel.png" -alpha off -gravity center -crop 2000x1125+0-40 +repage -resize 1600x900 \
    \( "$TMP/tooltip.png" -resize 150% -bordercolor '#555' -border 1 \) -gravity northeast -geometry +24+24 -composite \
    -strip $SMALL "PNG8:$OUT/cybertruck-musk.png"

identify -format '%f %wx%h\n' "$OUT/cybertruck-builds.png" "$OUT/cybertruck-musk.png"
