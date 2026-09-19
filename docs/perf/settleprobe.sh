#!/bin/bash
# When does the panel actually finish appearing, as the eye would judge it?
#
# The IPC stall probe only sees the GUI thread. Canvas painting runs on the
# render thread, so ten canvases can still be drawing themselves long after IPC
# says the shell is responsive. This captures frames of the panel region and
# hashes them: the panel has finished when consecutive frames stop differing.
#
# grim costs ~40-90 ms a frame, so resolution is coarse, but it is measuring the
# right thing: pixels, not readiness.
set -u
T=nixfred.pulse
OUT=${1:-/tmp/settle}
GEOM=${2:-}
mkdir -p "$OUT"; rm -f "$OUT"/f*.png

omarchy-shell $T close >/dev/null 2>&1; sleep 2

if [[ -z $GEOM ]]; then
  GEOM=$(omarchy-shell $T status | python3 -c "
import sys,json;d=json.load(sys.stdin)
print('%d,%d 1500x900' % (d.get('panelX',0), d.get('panelY',0)))")
fi

start=$(date +%s%N)
omarchy-shell $T toggle >/dev/null 2>&1 &
for i in $(seq -w 1 26); do
  grim -g "$GEOM" "$OUT/f$i.png" 2>/dev/null
  now=$(date +%s%N)
  echo "$i $(( (now-start)/1000000 )) $(sha1sum "$OUT/f$i.png" | cut -c1-12)"
done
omarchy-shell $T close >/dev/null 2>&1
