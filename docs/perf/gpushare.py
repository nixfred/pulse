#!/usr/bin/env python3
"""How much of the compositing GPU does the shell use, in a given panel state?

Per-client engine time from DRM fdinfo, summed per process over a window. Run it
with the panel closed and again with it open to see what a page actually costs
the machine that has to draw it.

    python3 docs/perf/gpushare.py 3 "panel closed"
"""
import glob
import sys
import time


def snap():
    out = {}
    for fd in glob.glob('/proc/[0-9]*/fdinfo/*'):
        try:
            txt = open(fd).read()
        except Exception:
            continue
        if 'drm-engine-' not in txt:
            continue
        pid = fd.split('/')[2]
        cid = None
        vals = {}
        for line in txt.splitlines():
            if line.startswith('drm-client-id:'):
                cid = line.split(':')[1].strip()
            elif line.startswith('drm-engine-'):
                key = line.split(':')[0].replace('drm-engine-', '')
                try:
                    vals[key] = int(line.split(':')[1].strip().split()[0])
                except (ValueError, IndexError):
                    pass
        if cid:
            out[(pid, cid)] = vals
    return out


def measure(seconds):
    before = snap()
    start = time.time()
    time.sleep(seconds)
    after = snap()
    wall = (time.time() - start) * 1e9
    totals = {}
    for key, vals in after.items():
        pid = key[0]
        prev = before.get(key, {})
        busy = sum(max(0, v - prev.get(k, v)) for k, v in vals.items())
        if busy <= 0:
            continue
        try:
            name = open('/proc/%s/comm' % pid).read().strip()
        except Exception:
            name = '?'
        totals[(pid, name)] = totals.get((pid, name), 0) + busy
    return wall, totals


if __name__ == '__main__':
    window = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
    label = sys.argv[2] if len(sys.argv) > 2 else ''
    wall, totals = measure(window)
    print('  %s' % label)
    for (pid, name), busy in sorted(totals.items(), key=lambda kv: -kv[1])[:6]:
        print('    %-18s pid %-8s %6.1f%% of wall' % (name, pid, busy / wall * 100))
    if not totals:
        print('    (nothing submitted work)')
