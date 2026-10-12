#!/usr/bin/env bash
# Renders the first-person camera's motion to look at: a landing, a run of hops, a strafe and
# the widening at speed, at 144 frames a second. See tools/render_feel.gd.
#
#   tools/render_feel.sh                 # landing, hop, strafe and speed
#   tools/render_feel.sh landing strafe  # some of them
#   tools/render_feel.sh --off           # every camera motion setting at 0: the control
#   RENDERER=forward_plus tools/render_feel.sh
#
# Writes screenshots/feel/<scenario>_NNN.png, <scenario>.csv (every frame) and
# <scenario>_sheet.png (the sequence on one page, if PIL is there). Needs xvfb-run: under
# --headless every saved frame is empty. Copied from game-arena's, as the family's rule is.
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/feel
mkdir -p "$out"
rm -f "$out"/*.png "$out"/*.csv
timeout 300 xvfb-run -a godot --path . --resolution 960x540 --fixed-fps 144 \
  ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://tools/render_feel.gd -- "$@"

# The log, read as a person reads the frames: each column's range, the largest change in a
# frame, and the largest change of that (a corner: a snap shows as a change of step as large
# as the step itself).
python3 - "$out" <<'PY'
import csv, glob, os, sys
out = sys.argv[1]
def steps(values):
    return [values[i + 1] - values[i] for i in range(len(values) - 1)]
def worst_change(values):
    s = steps(values)
    return max((abs(s[i + 1] - s[i]) for i in range(len(s) - 1)), default=0.0)
for path in sorted(glob.glob(os.path.join(out, "*.csv"))):
    rows = list(csv.DictReader(open(path)))
    name = os.path.basename(path)[:-4]
    if len(rows) < 4:
        print(f"{name}: {len(rows)} frames, nothing to read")
        continue
    speeds = [float(r["speed"]) for r in rows]
    print(f"{name}: {len(rows)} frames, horizontal speed {min(speeds):.1f}..{max(speeds):.1f} m/s")
    for col, unit, k in (("dip", "mm", 1000.0), ("roll", "deg", 1.0), ("fov", "deg", 1.0)):
        vs = [float(r[col]) * k for r in rows]
        s = steps(vs)
        print(f"  {col} {min(vs):.2f}..{max(vs):.2f} {unit}, largest step {max(abs(x) for x in s):.3f}, "
              f"largest change of step {worst_change(vs):.4f}")
    if name == "landing":
        ys = [float(r["eye_y"]) for r in rows[90:]]
        s = steps(ys)
        print(f"  eye step per frame {min(s) * 1000:.1f}..{max(s) * 1000:.1f} mm, largest change of step {worst_change(ys) * 1000:.1f} mm")
try:
    from PIL import Image
except ImportError:
    sys.exit(0)
for scenario in sorted({os.path.basename(p).rsplit("_", 1)[0] for p in glob.glob(os.path.join(out, "*_[0-9][0-9][0-9].png"))}):
    frames = sorted(glob.glob(os.path.join(out, f"{scenario}_[0-9][0-9][0-9].png")))
    thumbs = [Image.open(f).resize((320, 180)) for f in frames]
    cols = 6
    sheet = Image.new("RGB", (cols * 320, ((len(thumbs) + cols - 1) // cols) * 180))
    for i, t in enumerate(thumbs):
        sheet.paste(t, ((i % cols) * 320, (i // cols) * 180))
    sheet.save(os.path.join(out, f"{scenario}_sheet.png"))
    print(f"wrote {out}/{scenario}_sheet.png ({len(thumbs)} frames)")
PY
