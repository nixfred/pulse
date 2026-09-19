#!/usr/bin/env python3
"""Measure how long the shell's GUI thread is blocked, by pinging it constantly.

The panel's own `status` IPC is answered on the GUI thread. If that thread is
busy constructing or painting, the reply does not come back until it is free
again, so the WORST gap between consecutive replies is the length of the freeze
the user actually sees. Polling for "is it rendered yet" cannot see this: it
measures its own round trips too.

Floor is roughly 40 ms, the cost of one omarchy-shell invocation.
"""
import subprocess
import sys
import time

TARGET = 'nixfred.pulse'


def ping():
    t = time.perf_counter()
    subprocess.run(['omarchy-shell', TARGET, 'status'],
                   capture_output=True, timeout=30)
    return t, time.perf_counter()


def run(action, args, settle=6.0):
    subprocess.run(['omarchy-shell', TARGET, 'close'], capture_output=True)
    time.sleep(2.0)

    gaps = []
    # Warm the baseline: a few pings with nothing happening.
    for _ in range(6):
        a, b = ping()
        gaps.append((b - a) * 1000)
    baseline = min(gaps)

    fired = False
    start = time.perf_counter()
    worst = 0.0
    worst_at = 0.0
    while time.perf_counter() - start < settle:
        if not fired:
            subprocess.Popen(['omarchy-shell', TARGET] + [action] + args,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            fired = True
            fired_at = time.perf_counter()
        a, b = ping()
        gap = (b - a) * 1000
        if gap > worst:
            worst = gap
            worst_at = (a - fired_at) * 1000
    return baseline, worst, worst_at


if __name__ == '__main__':
    action = sys.argv[1] if len(sys.argv) > 1 else 'show'
    args = sys.argv[2:] if len(sys.argv) > 2 else ['overview']
    for run_index in range(3):
        baseline, worst, at = run(action, args)
        print('  run %d: idle ping %.0f ms | WORST STALL %.0f ms (began %.0f ms after the click)'
              % (run_index + 1, baseline, worst, at))
        sys.stdout.flush()
