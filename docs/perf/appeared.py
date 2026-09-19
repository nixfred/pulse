#!/usr/bin/env python3
"""When did the panel actually appear, and when did its layout stop moving?

Each captured frame is reduced to a tiny RGB thumbnail with ffmpeg (no image
library needed here) and compared against the final frame. The panel is "up"
once a frame is close to the final one; before that the screenshot is still
showing whatever was behind it.
"""
import subprocess, sys, glob, os

def thumb(path, w=24, h=14):
    out = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', path, '-vf', 'scale=%d:%d' % (w, h),
         '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
        capture_output=True)
    return out.stdout

def dist(a, b):
    if not a or not b or len(a) != len(b):
        return 1e9
    return sum(abs(a[i] - b[i]) for i in range(len(a))) / float(len(a))

frames = sorted(glob.glob(sys.argv[1] + '/f*.png'))
times = {}
for line in open(sys.argv[2]):
    parts = line.split()
    if len(parts) >= 2:
        times[parts[0]] = int(parts[1])

final = thumb(frames[-1])
print('  frame   t(ms)   difference-from-final')
appeared = None
for f in frames:
    idx = os.path.basename(f)[1:3]
    d = dist(thumb(f), final)
    ms = times.get(idx, 0)
    state = ''
    if d < 1.2 and appeared is None:
        appeared = ms; state = '  <-- panel is up'
    print('  %s  %6d   %8.1f%s' % (idx, ms, d, state))
if appeared is not None:
    print('\n  PANEL APPEARED at ~%d ms' % appeared)
else:
    print('\n  never converged on the final frame')
