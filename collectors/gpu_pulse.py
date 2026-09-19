#!/usr/bin/env python3
"""GPU Pulse: unprivileged telemetry, persistent history, focus-only navigation.

Three vendors, one shape:

  NVIDIA  `libnvidia-ml.so.1` through ctypes. A full sample measures 0.017 ms
          against 46-52 ms to fork `nvidia-smi`, so this daemon reads the same
          numbers `nvidia-smi` prints for roughly 1/2800th of the cost. That
          matters here: this plugin already had to be taught not to spend a
          slice of a core on readings nobody asked for, and a fork every three
          seconds would have put it straight back.
  Intel   i915/xe sysfs. `rc6_residency_ms` counts deep-idle time, so busy is
          what is left of the wall clock. Cross-checked on this machine against
          the per-client `drm-engine-render` deltas in fdinfo: 90% rc6-busy
          against 71% engine-busy, which is the gap you expect (a gt can be
          awake with nothing submitted).
  AMD     amdgpu's documented sysfs ABI. There is no AMD card on this machine,
          so those readings are written from the ABI and marked untested rather
          than claimed to work.

Every field degrades on its own. This laptop's NVML refuses fan speed and the
temperature threshold, so they come back as null and the panel shows a dash. A
confident 0 W or 0 RPM would be a lie.
"""
import argparse
import ctypes
import fcntl
import glob
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time

STATE = Path(os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state')) / 'gpu-pulse'
LINKS = {'repo': 'https://github.com/nixfred/pulse',
         'author': 'https://nixfred.com'}

# ---- NVML ----------------------------------------------------------------

NVML_SUCCESS = 0
NVML_TEMPERATURE_GPU = 0
NVML_CLOCK_SM = 0
NVML_CLOCK_MEM = 2
NVML_PCIE_UTIL_TX = 0
NVML_PCIE_UTIL_RX = 1

# nvmlClocksThrottleReason bits, in bit order.
THROTTLE_BITS = (
    (1 << 0, 'idle', 'Idle'),
    (1 << 1, 'appClocks', 'Application clock setting'),
    (1 << 2, 'swPowerCap', 'Power cap'),
    (1 << 3, 'hwSlowdown', 'Hardware slowdown'),
    (1 << 4, 'syncBoost', 'Sync boost'),
    (1 << 5, 'swThermal', 'Thermal (software)'),
    (1 << 6, 'hwThermal', 'Thermal (hardware)'),
    (1 << 7, 'hwPowerBrake', 'Power brake'),
    (1 << 8, 'displayClock', 'Display clock setting'),
)
# An idle card is not being held back, and the two "this is how it was
# configured" reasons are facts about the setup rather than constraints. Only
# the rest count as the GPU actually being held down.
THROTTLE_BENIGN = frozenset(('idle', 'appClocks', 'displayClock'))


class _Memory(ctypes.Structure):
    _fields_ = [('total', ctypes.c_ulonglong), ('free', ctypes.c_ulonglong),
                ('used', ctypes.c_ulonglong)]


class _Utilization(ctypes.Structure):
    _fields_ = [('gpu', ctypes.c_uint), ('memory', ctypes.c_uint)]


class _ProcInfo(ctypes.Structure):
    _fields_ = [('pid', ctypes.c_uint), ('usedGpuMemory', ctypes.c_ulonglong),
                ('gpuInstanceId', ctypes.c_uint), ('computeInstanceId', ctypes.c_uint)]


class _ProcUtil(ctypes.Structure):
    _fields_ = [('pid', ctypes.c_uint), ('timeStamp', ctypes.c_ulonglong),
                ('smUtil', ctypes.c_uint), ('memUtil', ctypes.c_uint),
                ('encUtil', ctypes.c_uint), ('decUtil', ctypes.c_uint)]


class _Violation(ctypes.Structure):
    _fields_ = [('referenceTime', ctypes.c_ulonglong),
                ('violationTime', ctypes.c_ulonglong)]


class Nvml(object):
    """A hand-rolled NVML binding.

    Deliberately not pynvml: it is not installed here, Omarchy plugins run on
    the system python with no virtualenv, and asking someone to pip install a
    package to see a bar readout is not a reasonable trade for five numbers.
    """

    def __init__(self):
        self.lib = None
        self.handles = []
        self.reason = ''

    def start(self):
        try:
            lib = ctypes.CDLL('libnvidia-ml.so.1')
        except OSError:
            self.reason = 'no NVIDIA driver on this machine'
            return False
        if lib.nvmlInit_v2() != NVML_SUCCESS:
            self.reason = 'NVML is present but would not initialise'
            return False
        self.lib = lib
        count = ctypes.c_uint()
        if lib.nvmlDeviceGetCount_v2(ctypes.byref(count)) != NVML_SUCCESS:
            self.reason = 'NVML would not count devices'
            return False
        for index in range(count.value):
            handle = ctypes.c_void_p()
            if lib.nvmlDeviceGetHandleByIndex_v2(index, ctypes.byref(handle)) == NVML_SUCCESS:
                self.handles.append(handle)
        return bool(self.handles)

    def _u32(self, name, handle, *args):
        fn = getattr(self.lib, name, None)
        if fn is None:
            return None
        value = ctypes.c_uint()
        rc = fn(handle, *(list(args) + [ctypes.byref(value)]))
        return value.value if rc == NVML_SUCCESS else None

    def _u64(self, name, handle, *args):
        fn = getattr(self.lib, name, None)
        if fn is None:
            return None
        value = ctypes.c_ulonglong()
        rc = fn(handle, *(list(args) + [ctypes.byref(value)]))
        return value.value if rc == NVML_SUCCESS else None

    def _text(self, name, handle, size=96):
        fn = getattr(self.lib, name, None)
        if fn is None:
            return ''
        buf = ctypes.create_string_buffer(size)
        rc = fn(handle, buf, size)
        return buf.value.decode('utf-8', 'replace') if rc == NVML_SUCCESS else ''

    def driver(self):
        buf = ctypes.create_string_buffer(80)
        if self.lib and self.lib.nvmlSystemGetDriverVersion(buf, 80) == NVML_SUCCESS:
            return buf.value.decode('utf-8', 'replace')
        return ''

    def sample(self, handle):
        util = _Utilization()
        ok = self.lib.nvmlDeviceGetUtilizationRates(handle, ctypes.byref(util)) == NVML_SUCCESS
        mem = _Memory()
        mem_ok = self.lib.nvmlDeviceGetMemoryInfo(handle, ctypes.byref(mem)) == NVML_SUCCESS

        power = self._u32('nvmlDeviceGetPowerUsage', handle)
        limit = self._u32('nvmlDeviceGetEnforcedPowerLimit', handle)
        mask = self._u64('nvmlDeviceGetCurrentClocksThrottleReasons', handle) or 0
        reasons = [key for bit, key, _ in THROTTLE_BITS if mask & bit]
        total = mem.total if mem_ok else None
        used = mem.used if mem_ok else None

        return {
            'vendor': 'nvidia',
            'name': self._text('nvmlDeviceGetName', handle) or 'NVIDIA GPU',
            'busyPct': util.gpu if ok else None,
            'memIoPct': util.memory if ok else None,
            'memTotal': total,
            'memUsed': used,
            'memUsedPct': None if not total else round(used / float(total) * 100.0, 1),
            'tempC': self._u32('nvmlDeviceGetTemperature', handle,
                               ctypes.c_int(NVML_TEMPERATURE_GPU)),
            'powerW': None if power is None else round(power / 1000.0, 2),
            'powerLimitW': None if limit is None else round(limit / 1000.0, 2),
            'clockSmMhz': self._u32('nvmlDeviceGetClockInfo', handle,
                                    ctypes.c_int(NVML_CLOCK_SM)),
            'clockMemMhz': self._u32('nvmlDeviceGetClockInfo', handle,
                                     ctypes.c_int(NVML_CLOCK_MEM)),
            'clockSmMaxMhz': self._u32('nvmlDeviceGetMaxClockInfo', handle,
                                       ctypes.c_int(NVML_CLOCK_SM)),
            # Unsupported on this laptop. Null, so the panel shows a dash.
            'fanPct': self._u32('nvmlDeviceGetFanSpeed', handle),
            'pstate': self._u32('nvmlDeviceGetPerformanceState', handle),
            'pcieGen': self._u32('nvmlDeviceGetCurrPcieLinkGeneration', handle),
            'pcieWidth': self._u32('nvmlDeviceGetCurrPcieLinkWidth', handle),
            'pcieTxKbs': self._u32('nvmlDeviceGetPcieThroughput', handle,
                                   ctypes.c_int(NVML_PCIE_UTIL_TX)),
            'pcieRxKbs': self._u32('nvmlDeviceGetPcieThroughput', handle,
                                   ctypes.c_int(NVML_PCIE_UTIL_RX)),
            'encoderPct': self._encoder(handle),
            'throttleMask': mask,
            'throttleReasons': reasons,
            'throttleActive': [r for r in reasons if r not in THROTTLE_BENIGN],
            'violations': self._violations(handle),
        }

    def _encoder(self, handle):
        fn = getattr(self.lib, 'nvmlDeviceGetEncoderUtilization', None)
        if fn is None:
            return None
        util = ctypes.c_uint()
        period = ctypes.c_uint()
        rc = fn(handle, ctypes.byref(util), ctypes.byref(period))
        return util.value if rc == NVML_SUCCESS else None

    def _violations(self, handle):
        """Raw power and thermal violation counters, cumulative since boot.

        Stored raw and turned into a rate by `throttle_rate()` below. Read as a
        total this counter says the card has been power-throttled for 236,519
        seconds, which is true and useless: it is a laptop GPU that has been
        at its 40 W cap since boot. The CPU domain shipped exactly that bug
        once (fixed in 02e0613) and it is not shipping again here.
        """
        fn = getattr(self.lib, 'nvmlDeviceGetViolationStatus', None)
        if fn is None:
            return {}
        out = {}
        for label, policy in (('power', 0), ('thermal', 1)):
            status = _Violation()
            if fn(handle, ctypes.c_int(policy), ctypes.byref(status)) == NVML_SUCCESS:
                out[label] = {'violationNs': status.violationTime,
                              'referenceNs': status.referenceTime}
        return out

    def processes(self, handle):
        """Per-process VRAM, and per-process SM% where the driver offers it."""
        out = {}
        for name in ('nvmlDeviceGetComputeRunningProcesses_v3',
                     'nvmlDeviceGetGraphicsRunningProcesses_v3'):
            fn = getattr(self.lib, name, None)
            if fn is None:
                continue
            count = ctypes.c_uint(0)
            fn(handle, ctypes.byref(count), None)
            room = max(count.value, 4) + 8
            arr = (_ProcInfo * room)()
            got = ctypes.c_uint(room)
            if fn(handle, ctypes.byref(got), arr) != NVML_SUCCESS:
                continue
            kind = 'graphics' if 'Graphics' in name else 'compute'
            for i in range(min(got.value, room)):
                entry = arr[i]
                if not entry.pid:
                    continue
                row = out.setdefault(entry.pid, {'pid': entry.pid, 'kind': kind,
                                                 'memBytes': 0, 'smPct': None})
                row['memBytes'] = max(row['memBytes'], int(entry.usedGpuMemory))

        fn = getattr(self.lib, 'nvmlDeviceGetProcessUtilization', None)
        if fn is not None:
            count = ctypes.c_uint(0)
            fn(handle, None, ctypes.byref(count), ctypes.c_ulonglong(0))
            room = max(count.value, 4) + 8
            arr = (_ProcUtil * room)()
            got = ctypes.c_uint(room)
            # Samples from the last second only; older ones describe a process
            # that may already be gone.
            since = ctypes.c_ulonglong(int((time.time() - 1.0) * 1e6))
            if fn(handle, arr, ctypes.byref(got), since) == NVML_SUCCESS:
                for i in range(min(got.value, room)):
                    entry = arr[i]
                    if not entry.pid:
                        continue
                    row = out.setdefault(entry.pid, {'pid': entry.pid, 'kind': 'compute',
                                                     'memBytes': 0, 'smPct': None})
                    row['smPct'] = entry.smUtil
        return list(out.values())


# ---- sysfs ---------------------------------------------------------------

def read_text(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except (OSError, ValueError):
        return ''


def read_int(path):
    try:
        return int(read_text(path))
    except ValueError:
        return None


def drm_cards(vendor):
    return [card for card in sorted(glob.glob('/sys/class/drm/card[0-9]'))
            if read_text(os.path.join(card, 'device/vendor')) == vendor]


def intel_cards():
    """Intel render nodes, with whichever gt layout the driver uses.

    i915 exposes card/gt/gt<N>/, xe exposes card/device/tile<N>/gt<N>/. Both are
    looked for because Arrow Lake ships with either depending on the kernel; on
    this machine it is i915.
    """
    cards = []
    for card in drm_cards('0x8086'):
        gts = sorted(glob.glob(os.path.join(card, 'gt/gt[0-9]')))
        if not gts:
            gts = sorted(glob.glob(os.path.join(card, 'device/tile[0-9]/gt[0-9]')))
        if gts:
            cards.append({'path': card, 'gts': gts})
    return cards


def intel_sample(card, previous):
    """Busy from the complement of rc6 deep-idle residency, plus gt clocks."""
    now = time.time()
    render = card['gts'][0]
    rc6 = read_int(os.path.join(render, 'rc6_residency_ms'))
    state = {'rc6': rc6, 'ts': now}

    busy = None
    if previous and previous.get('rc6') is not None and rc6 is not None:
        wall_ms = (now - previous['ts']) * 1000.0
        idle_ms = rc6 - previous['rc6']
        # A negative delta means the counter wrapped or the module reloaded.
        if wall_ms > 0 and idle_ms >= 0:
            busy = round(max(0.0, min(100.0, (1.0 - idle_ms / wall_ms) * 100.0)), 1)

    tiles = [{'gt': os.path.basename(gt),
              'mhz': read_int(os.path.join(gt, 'rps_act_freq_mhz')),
              'maxMhz': read_int(os.path.join(gt, 'rps_max_freq_mhz'))}
             for gt in card['gts']]

    return {
        'vendor': 'intel',
        'name': 'Intel integrated graphics',
        'busyPct': busy,
        'busyMethod': 'rc6 residency',
        'clockSmMhz': tiles[0]['mhz'] if tiles else None,
        'clockSmMaxMhz': tiles[0]['maxMhz'] if tiles else None,
        'tiles': tiles,
        # An integrated GPU has no memory of its own; it spends system RAM,
        # which the RAM domain already reports honestly.
        'memTotal': None, 'memUsed': None, 'memUsedPct': None,
        'tempC': None, 'powerW': None, 'powerLimitW': None,
        'throttleReasons': [], 'throttleActive': [], 'violations': {},
    }, state


def amd_sample(card):
    """amdgpu's documented sysfs ABI. UNTESTED: no AMD card on this machine."""
    device = os.path.join(card, 'device')
    hwmon = (sorted(glob.glob(os.path.join(device, 'hwmon/hwmon*'))) or [None])[0]
    temp = power = None
    if hwmon:
        raw = read_int(os.path.join(hwmon, 'temp1_input'))
        temp = None if raw is None else round(raw / 1000.0)
        raw = read_int(os.path.join(hwmon, 'power1_average'))
        power = None if raw is None else round(raw / 1000000.0, 2)
    total = read_int(os.path.join(device, 'mem_info_vram_total'))
    used = read_int(os.path.join(device, 'mem_info_vram_used'))
    return {
        'vendor': 'amd',
        'name': read_text(os.path.join(device, 'product_name')) or 'AMD graphics',
        'busyPct': read_int(os.path.join(device, 'gpu_busy_percent')),
        'memTotal': total,
        'memUsed': used,
        'memUsedPct': None if not total else round((used or 0) / float(total) * 100.0, 1),
        'tempC': temp,
        'powerW': power,
        'powerLimitW': None,
        'clockSmMhz': None, 'clockSmMaxMhz': None,
        'throttleReasons': [], 'throttleActive': [], 'violations': {},
        'untested': True,
    }


# ---- assembly ------------------------------------------------------------

NVML = Nvml()
NVML_READY = NVML.start()
INTEL = intel_cards()
AMD = drm_cards('0x1002')


def throttle_rate(card, previous_card):
    """Seconds of violation per minute, from two cumulative readings.

    The counters only mean something as a difference. A machine that was
    power-capped for an hour this morning is not being throttled now, and the
    total cannot tell those apart. The live reason mask is the corroboration:
    a rate with no reason currently lit is history, not a constraint, which is
    the same rule the disk domain learned when io_uring waits were inflating
    pressure with no drive to back them up.
    """
    out = {}
    now = card.get('violations') or {}
    was = (previous_card or {}).get('violations') or {}
    for label, current in now.items():
        before = was.get(label)
        if not before:
            continue
        span_ns = current.get('referenceNs', 0) - before.get('referenceNs', 0)
        viol_ns = current.get('violationNs', 0) - before.get('violationNs', 0)
        if span_ns <= 0 or viol_ns < 0:
            continue
        out[label] = round(min(60.0, viol_ns / float(span_ns) * 60.0), 2)
    return out


def sample_cards(previous):
    """Every GPU, discrete first: it is the one that runs out and holds work up."""
    previous = previous or {}
    cards = []
    intel_state = {}

    if NVML_READY:
        for index, handle in enumerate(NVML.handles):
            card = NVML.sample(handle)
            card['id'] = 'nvidia:%d' % index
            card['discrete'] = True
            cards.append(card)
    for index, path in enumerate(AMD):
        card = amd_sample(path)
        card['id'] = 'amd:%d' % index
        card['discrete'] = True
        cards.append(card)
    for index, card_paths in enumerate(INTEL):
        key = 'intel:%d' % index
        card, state = intel_sample(card_paths, (previous.get('intelState') or {}).get(key))
        card['id'] = key
        card['discrete'] = False
        intel_state[key] = state
        cards.append(card)

    prior = {c.get('id'): c for c in (previous.get('cards') or [])}
    for card in cards:
        card['throttleRate'] = throttle_rate(card, prior.get(card.get('id')))
        limit = card.get('powerLimitW')
        draw = card.get('powerW')
        card['powerPct'] = (None if not limit or draw is None
                            else round(min(100.0, draw / limit * 100.0), 1))
        top = card.get('clockSmMaxMhz')
        cur = card.get('clockSmMhz')
        card['clockPct'] = (None if not top or cur is None
                            else round(min(100.0, cur / float(top) * 100.0), 1))
    return cards, intel_state


def metrics(previous=None):
    ts = time.time()
    monotonic = time.monotonic()
    cards, intel_state = sample_cards(previous)

    # The headline card is the discrete one if there is one. On a laptop the
    # integrated GPU is what draws the screen, but the discrete card is what
    # runs out of memory and what work waits on.
    primary = next((c for c in cards if c.get('discrete')), cards[0] if cards else {})

    return {
        'ts': ts,
        'monotonic': monotonic,
        # Warm on the second pass: the Intel busy figure is a delta and the
        # throttle rate needs two readings before either means anything.
        'warm': bool(previous),
        'present': bool(cards),
        'reason': '' if cards else (NVML.reason or 'no GPU found on this machine'),
        'vendor': primary.get('vendor', ''),
        'name': primary.get('name', ''),
        'driver': NVML.driver() if NVML_READY else '',
        'busyPct': primary.get('busyPct'),
        'memUsedPct': primary.get('memUsedPct'),
        'memUsed': primary.get('memUsed'),
        'memTotal': primary.get('memTotal'),
        'tempC': primary.get('tempC'),
        'powerW': primary.get('powerW'),
        'powerLimitW': primary.get('powerLimitW'),
        'powerPct': primary.get('powerPct'),
        'clockSmMhz': primary.get('clockSmMhz'),
        'clockSmMaxMhz': primary.get('clockSmMaxMhz'),
        'clockPct': primary.get('clockPct'),
        'fanPct': primary.get('fanPct'),
        'encoderPct': primary.get('encoderPct'),
        'pstate': primary.get('pstate'),
        'throttleReasons': primary.get('throttleReasons', []),
        'throttleActive': primary.get('throttleActive', []),
        'throttleRate': primary.get('throttleRate', {}),
        'primaryId': primary.get('id', ''),
        'cards': cards,
        'intelState': intel_state,
        'count': len(cards),
    }


# ---- history -------------------------------------------------------------

def db_open():
    db = sqlite3.connect(STATE / 'history.sqlite3', timeout=5)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, busy REAL, temp REAL, mem REAL, power REAL, boot TEXT)')
    return db


def record(db, m):
    db.execute('INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?)',
               (m['ts'], m.get('busyPct'), m.get('tempC'), m.get('memUsedPct'),
                m.get('powerW'), read_text('/proc/sys/kernel/random/boot_id')))
    db.execute('DELETE FROM samples WHERE ts < ?', (m['ts'] - 7 * 86400,))
    db.commit()


def history(db, seconds, now=None):
    now = time.time() if now is None else now
    bucket = max(15, seconds / 240)
    # Boot is part of each bucket; never draw a line across a reboot.
    rows = db.execute(
        'SELECT MIN(ts), AVG(busy), MAX(busy), AVG(NULLIF(temp, 0)), MAX(mem), COUNT(*), boot '
        'FROM samples WHERE ts>=? AND ts<=? GROUP BY CAST(ts/? AS INTEGER), boot ORDER BY MIN(ts)',
        (now - seconds, now, bucket)).fetchall()
    return {'seconds': seconds, 'bucket': bucket, 'now': now, 'points': rows,
            'count': sum(r[5] for r in rows), 'peak': max((r[2] or 0 for r in rows), default=0)}


def atomic(name, value):
    path = STATE / name
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, separators=(',', ':'), ensure_ascii=True))
    tmp.replace(path)


# ---- demand-driven process scanning ---------------------------------------
# Reading which processes hold VRAM means asking NVML per card and then reading
# /proc for each pid to name it. It is far cheaper than the CPU domain's walk,
# but it is still work with exactly one consumer: the hogs tab. The panel
# refreshes `want-processes` while that tab is on screen; a stale marker means
# nobody is looking and the scan is skipped.
WANT_PROCESSES = STATE / 'want-processes'
WANT_TTL = 30


def processes_wanted():
    try:
        return time.time() - WANT_PROCESSES.stat().st_mtime < WANT_TTL
    except OSError:
        return False


def process_name(pid):
    name = read_text('/proc/%d/comm' % pid)
    if not name:
        return ''
    # A command line says far more than the comm for the things that hold VRAM:
    # "llama-server" alone does not say which model is resident.
    try:
        with open('/proc/%d/cmdline' % pid, 'rb') as handle:
            parts = [p.decode('utf-8', 'replace') for p in handle.read().split(b'\0') if p]
    except OSError:
        parts = []
    detail = ''
    for index, part in enumerate(parts):
        if part in ('-m', '--model') and index + 1 < len(parts):
            detail = os.path.basename(parts[index + 1])
            break
    return name if not detail else name + '  ·  ' + detail


def process_start(pid):
    """Start time in clock ticks, the half of a process's identity that a
    recycled PID cannot forge."""
    try:
        with open('/proc/%d/stat' % pid) as handle:
            return handle.read().rpartition(')')[2].split()[19]
    except (OSError, IndexError):
        return ''


def hogs(cards):
    rows = []
    if not NVML_READY:
        return rows
    for index, handle in enumerate(NVML.handles):
        card_id = 'nvidia:%d' % index
        for proc in NVML.processes(handle):
            pid = proc['pid']
            name = process_name(pid)
            if not name:
                continue  # exited between the NVML call and reading /proc
            rows.append({
                'pid': pid,
                'name': name,
                'start': process_start(pid),
                'memBytes': proc['memBytes'],
                'smPct': proc['smPct'],
                'kind': proc['kind'],
                'card': card_id,
                'mine': owned_by_me(pid),
            })
    rows.sort(key=lambda r: (r['memBytes'], r['smPct'] or 0), reverse=True)
    return rows


def owned_by_me(pid):
    try:
        return os.stat('/proc/%d' % pid).st_uid == os.getuid()
    except OSError:
        return False


def daemon():
    with (STATE / 'collector.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        db = db_open()
        previous = None
        last_history = last_procs = 0
        was_wanted = False
        rows = []
        while True:
            start = time.monotonic()
            try:
                m = metrics(previous)
                if m['warm'] and m['present'] and start - last_history >= 15:
                    record(db, m)
                    atomic('history.json',
                           {str(s): history(db, s, m['ts']) for s in (3600, 86400, 604800)})
                    last_history = start
                wanted = processes_wanted()
                if wanted and (start - last_procs >= 9 or not was_wanted):
                    rows = hogs(m['cards'])
                    last_procs = start
                elif not wanted:
                    rows = []
                was_wanted = wanted
                m['hogs'] = rows
                if m['warm']:
                    atomic('snapshot.json', m)
                previous = m
            except (OSError, sqlite3.Error, RuntimeError, ValueError) as e:
                print('GPU Pulse: %s: %s' % (type(e).__name__, e), flush=True)
            time.sleep(max(0.2, 3 - (time.monotonic() - start)))


def focus(pid, start):
    """Bring a GPU process's window forward, through the CPU domain's router.

    The routing (herdr panes, tmux panes, Hyprland windows, browser
    subprocesses leading to their browser) is already written and already
    maintained one directory over. Copying 250 lines of it here would mean two
    copies to fix the next time a compositor changes its dispatch syntax.
    """
    try:
        import cpu_pulse
    except ImportError:
        raise RuntimeError('Window routing needs the CPU collector beside this one.')
    return cpu_pulse.focus(pid, start)


def visit(link):
    # The panel names a link, it never supplies a URL, so nothing reaching
    # xdg-open came from a snapshot or a process name.
    url = LINKS.get(link)
    if not url:
        raise RuntimeError('Unknown link.')
    if not shutil.which('xdg-open'):
        raise RuntimeError('No xdg-open on PATH. The address is ' + url)
    subprocess.Popen(['xdg-open', url], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return {'message': 'Handed ' + url + ' to your browser.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['daemon', 'snapshot', 'focus', 'visit'])
    parser.add_argument('args', nargs='*')
    parser.add_argument('--link', choices=sorted(LINKS))
    args = parser.parse_args()
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        if args.action == 'daemon':
            daemon()
            return
        if args.action == 'snapshot':
            first = metrics()
            # Two passes: the Intel busy figure and the throttle rate are both
            # differences, and one reading cannot produce either.
            time.sleep(0.5)
            value = metrics(first)
            value['hogs'] = hogs(value['cards'])
        elif args.action == 'visit':
            value = visit(args.link)
        else:
            if len(args.args) != 2 or not args.args[0].isdigit():
                raise RuntimeError('focus needs a PID and a start time.')
            value = focus(int(args.args[0]), args.args[1])
        print(json.dumps(value))
    except Exception as e:
        print(json.dumps({'error': str(e)}))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
