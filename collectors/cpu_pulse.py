#!/usr/bin/env python3
"""CPU Pulse: unprivileged telemetry, persistent history, focus-only navigation."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import tempfile
import time

_state_home = os.environ.get('XDG_STATE_HOME','')
STATE = (Path(_state_home) if os.path.isabs(_state_home) else Path.home()/'.local/state')/'cpu-pulse'
ENV_KEYS = {'HERDR_ENV', 'HERDR_SOCKET_PATH', 'HERDR_WORKSPACE_ID', 'HERDR_TAB_ID', 'HERDR_PANE_ID', 'TMUX', 'TMUX_PANE', 'BOOMUX_SHELL_ID'}
PROFILES = ('power-saver', 'balanced', 'performance')
LINKS = {'repo': 'https://github.com/nixfred/omacpu',
         'author': 'https://nixfred.com'}
SYS_CPU = Path('/sys/devices/system/cpu')
try:
    CLK = os.sysconf('SC_CLK_TCK')
except (AttributeError, OSError, ValueError):
    CLK = 100
# Columns of a /proc/stat cpu line. guest and guest_nice are already inside
# user and nice, so they never join the total.
STAT_FIELDS = ('user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal')

def read(path):
    try:
        return Path(path).read_text(errors='replace')
    except (OSError, ValueError):
        return ''

def read_int(path):
    try:
        return int(read(path).split()[0])
    except (ValueError, IndexError):
        return None

C_LOCALE = dict(os.environ, LC_ALL='C', LANG='C')

def run(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=2, check=False, env=C_LOCALE)
        return p.stdout if p.returncode == 0 else ''
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return ''

def clients(query=None):
    query = run if query is None else query
    try:
        value = json.loads(query(['hyprctl', 'clients', '-j']))
        if not isinstance(value, list):
            return []
        result = []
        for c in value:
            if not isinstance(c, dict) or type(c.get('pid')) is not int or c['pid'] <= 0:
                continue
            if not re.fullmatch(r'0x[0-9a-fA-F]+', str(c.get('address', ''))):
                continue
            if not isinstance(c.get('workspace'), dict):
                c = dict(c, workspace={})
            result.append(c)
        return result
    except (ValueError, TypeError):
        return []

def environment(pid):
    # Only these routing identities ever leave this function. No credentials,
    # command lines, or full process environments are persisted.
    return {k: v for s in read(f'/proc/{pid}/environ').split('\0') for k, sep, v in [s.partition('=')] if sep and k in ENV_KEYS}

def process(pid):
    raw = read(f'/proc/{pid}/stat')
    if not raw:
        return None
    try:
        tail = raw[raw.rindex(')') + 2:].split()
        return {'pid': int(pid), 'start': tail[19], 'ppid': int(tail[1]), 'state': tail[0],
                'name': raw[raw.index('(')+1:raw.rindex(')')][:64],
                'ticks': int(tail[11]) + int(tail[12]), 'nice': int(tail[16]), 'threads': int(tail[17])}
    except (ValueError, IndexError):
        return None

def window_for(pid, procs, windows):
    seen = set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        if pid in windows:
            return windows[pid]
        pid = procs.get(pid, {}).get('ppid', 0)
    return None

def owned_socket(path):
    # Herdr/TMUX socket paths come from the target process's own environment,
    # so they are attacker-influenced. Only a path that is currently a socket
    # owned by this user is usable; anything else degrades to plain window
    # focus rather than failing the click.
    try:
        info = os.stat(path)
    except (OSError, ValueError, TypeError):
        return ''
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        return ''
    return path

def related(a, b, procs):
    # A window title is attacker-reproducible: any same-user client can set
    # its title to match. A focus target the process tree cannot relate to
    # the target process is title-only evidence. Either direction counts, so
    # a terminal emulator above the shell and a helper below it both bind.
    for start, goal in ((a, b), (b, a)):
        seen = set()
        pid = start
        while isinstance(pid, int) and pid > 1 and pid not in seen:
            if pid == goal:
                return True
            seen.add(pid)
            pid = procs.get(pid, {}).get('ppid', 0)
    return False

def target_for(p, procs, wins, query=None):
    query = run if query is None else query
    windows = {c['pid']: c for c in wins}
    w = window_for(p['pid'], procs, windows)
    env = environment(p['pid'])
    host = {}
    # Boomux terminal titles carry an exact shell id. Focusing that existing
    # window needs no launcher and cannot create or terminate a session.
    # Titles alone do not bind a window to a shell -- any same-user client
    # can set its title -- so a candidate whose window process the tree
    # relates to the target wins over one that merely matches the title. The
    # title-only fallback stays for multiplexer layouts where the window and
    # the shell share no ancestry, where no better binding is available.
    shell = env.get('BOOMUX_SHELL_ID', '')
    if shell and re.fullmatch(r'\S{1,64}', shell):
        match = [c for c in wins if str(c.get('title', '')).startswith('boomux:shell:') and str(c.get('title', '')).split(' ')[0].endswith(':' + shell)]
        if match:
            kin = [c for c in match if isinstance(c.get('pid'), int) and related(p['pid'], c['pid'], procs)]
            w = kin[0] if kin else match[0]
    if not shell and env.get('HERDR_ENV') == '1' and env.get('HERDR_PANE_ID'):
        sock = owned_socket(env.get('HERDR_SOCKET_PATH') or str(Path.home() / '.config/herdr/herdr.sock'))
        if sock:
            for q in procs.values():
                if q['name'] != 'herdr':
                    continue
                cw = window_for(q['pid'], procs, windows)
                ce = environment(q['pid'])
                cs = ce.get('HERDR_SOCKET_PATH') or str(Path.home() / '.config/herdr/herdr.sock')
                if cw and cs == sock:
                    w = cw
                    host = {'kind': 'herdr', 'socket': sock, 'workspace': env.get('HERDR_WORKSPACE_ID', ''), 'tab': env.get('HERDR_TAB_ID', ''), 'pane': env['HERDR_PANE_ID']}
                    break
    if not shell and not host and env.get('TMUX') and re.fullmatch(r'%\d+', env.get('TMUX_PANE', '')):
        sock = owned_socket(env['TMUX'].rsplit(',', 2)[0])
        if sock:
            pane = env['TMUX_PANE']
            # Attach only to a client already displaying this pane's session.
            session = query(['tmux', '-S', sock, 'display-message', '-p', '-t', pane, '#{session_id}']).strip()
            for line in (query(['tmux', '-S', sock, 'list-clients', '-F', '#{client_pid}\t#{session_id}\t#{client_name}']) if session else '').splitlines():
                parts = line.split('\t')
                if len(parts) == 3 and parts[0].isdigit() and parts[1] == session:
                    cw = window_for(int(parts[0]), procs, windows)
                    if cw:
                        w = cw
                        host = {'kind': 'tmux', 'socket': sock, 'pane': pane, 'client': parts[2]}
                        break
    return {'address': w['address'], 'title': str(w.get('title', ''))[:100], 'workspace': str(w.get('workspace', {}).get('name', '')), 'host': host} if w else {}

def all_processes():
    procs = {}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            p = process(entry.name)
            if p:
                procs[p['pid']] = p
    return procs

def hogs(previous=None, now=None):
    """Top 24 processes by CPU time rate. previous maps (pid, start) -> (ticks, ts)
    from the last scan; a process seen for the first time reports its lifetime
    average instead of being hidden. Returns (rows, ticks) so the daemon can
    carry the new tick table forward."""
    now = time.monotonic() if now is None else now
    uptime = float((read('/proc/uptime').split() or ['0'])[0])
    procs = all_processes()
    ticks = {}
    for p in procs.values():
        key = (p['pid'], p['start'])
        ticks[key] = (p['ticks'], now)
        old = (previous or {}).get(key)
        if old and now - old[1] > 0:
            p['cpu'] = max(0, p['ticks'] - old[0]) / CLK / (now - old[1]) * 100
            p['sampled'] = True
        else:
            age = max(0.5, uptime - int(p['start']) / CLK)
            p['cpu'] = p['ticks'] / CLK / age * 100 if uptime > 0 else 0
            p['sampled'] = False
    wins = clients()
    rows = sorted(procs.values(), key=lambda p: (p['cpu'], p['ticks']), reverse=True)[:24]
    for p in rows:
        try:
            p['owned'] = Path(f"/proc/{p['pid']}").stat().st_uid == os.getuid()
        except OSError:
            p['owned'] = False
        p['target'] = target_for(p, procs, wins) if p['owned'] else {}
    return rows, ticks

def cpu_lines(raw):
    result = {}
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) >= 5 and re.fullmatch(r'cpu[0-9]*', parts[0]):
            try:
                values = [int(v) for v in parts[1:9]]
                result[parts[0]] = values + [0] * (8 - len(values))
            except ValueError:
                pass
    return result

def usage(now, then):
    """Busy percentage and per-field breakdown between two /proc/stat cpu rows."""
    # A reset/wrap invalidates this interval; iowait alone may decrease normally.
    reset = then and any(a < b for i, (a, b) in enumerate(zip(now, then)) if i != 4)
    delta = [max(0, a - b) for a, b in zip(now, then)] if then and not reset else [0] * 8
    total = sum(delta)
    if total <= 0:
        return 0.0, {k: 0.0 for k in STAT_FIELDS}
    breakdown = {k: v / total * 100 for k, v in zip(STAT_FIELDS, delta)}
    return max(0.0, min(100.0, 100 - breakdown['idle'] - breakdown['iowait'])), breakdown

def temperatures():
    package, cores, sensors = None, {}, []
    for h in sorted(Path('/sys/class/hwmon').glob('hwmon*')):
        chip = read(h / 'name').strip()
        if chip not in ('coretemp', 'k10temp', 'zenpower', 'applesmc'):
            continue
        package_id = None
        for label_file in h.glob('temp*_label'):
            match = re.fullmatch(r'Package id (\d+)', read(label_file).strip())
            if match:
                package_id = int(match[1])
                break
        for f in sorted(h.glob('temp*_input'), key=lambda f: int(re.sub(r'\D', '', f.name) or 0)):
            label = read(f.with_name(f.name.replace('_input', '_label'))).strip()
            value = read_int(f)
            if value is None:
                continue
            value /= 1000
            if label.startswith('Package id'):
                package = value if package is None else max(package, value)
            elif label.startswith('Core '):
                cores[(package_id, label[5:])] = value
            elif chip in ('k10temp', 'zenpower', 'applesmc') and not label:
                label = chip
                package = value if package is None else max(package, value)
            elif chip in ('k10temp', 'zenpower', 'applesmc'):
                # AMD/Apple chips expose Tctl/Tdie-style labels without a
                # Package id row; treat the hottest reading as the package
                # fallback so temp still reports without coretemp.
                package = value if package is None else max(package, value)
            sensors.append({'label': label or chip, 'temp': value})
    fallback = None
    for z in sorted(Path('/sys/class/thermal').glob('thermal_zone*'), key=lambda z: int(re.sub(r'\D', '', z.name) or 0)):
        kind = read(z / 'type').strip()
        value = read_int(z / 'temp')
        if value is None or value <= 0:
            continue
        value /= 1000
        if kind in ('x86_pkg_temp', 'TCPU', 'cpu-thermal', 'cpu_thermal', 'soc_thermal', 'acpitz', 'CPU', 'k10temp', 'zenpower', 'applesmc', 'arm', 'gpu'):
            fallback = value if fallback is None else fallback
            if kind != 'x86_pkg_temp' or package is None:
                sensors.append({'label': kind, 'temp': value})
    return package if package is not None else fallback, cores, sensors[:16]

def frequency():
    base = SYS_CPU / 'cpu0/cpufreq'
    for candidate in sorted(SYS_CPU.glob('cpu[0-9]*/cpufreq')):
        if read_int(candidate.parent / 'online') != 0:
            base = candidate
            break
    turbo = None
    no_turbo = read_int(SYS_CPU / 'intel_pstate/no_turbo')
    boost = read_int(SYS_CPU / 'cpufreq/boost')
    if no_turbo is not None:
        turbo = no_turbo == 0
    elif boost is not None:
        turbo = boost == 1
    return {'max': read_int(base / 'cpuinfo_max_freq'), 'min': read_int(base / 'cpuinfo_min_freq'), 'base': read_int(base / 'base_frequency'),
            'governor': read(base / 'scaling_governor').strip(), 'driver': read(base / 'scaling_driver').strip(),
            'epp': read(base / 'energy_performance_preference').strip(), 'turbo': turbo}

# The power profile is a fork+exec of powerprofilesctl, measured at 0.146 s —
# on its own, 82% of this daemon's entire cost when it ran every tick. The
# value only changes when somebody changes it, so it is cached. The panel's own
# profile action invalidates the cache by touching this file, so a switch made
# from the dashboard still shows up on the next tick rather than in half a
# minute.
PROFILE_TTL = 30
PROFILE_STAMP = STATE / 'profile-changed'
_profile = {'value': '', 'at': 0.0, 'stamp': 0.0}


def touch_marker(path):
    # The stamp is opened with O_NOFOLLOW so a symlinked stamp is refused
    # with ELOOP rather than followed and written through. A deliberate
    # dotfiles arrangement that symlinks state files keeps working for the
    # rename(2)-replaced snapshots, but this in-place stamp is refused: the
    # caller treats that as "no invalidation" and the cached profile simply
    # expires on PROFILE_TTL instead.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError as e:
        if e.errno == errno.ELOOP:
            return
        raise
    try:
        try:
            os.futimens(fd, None)
        except AttributeError:
            os.utime(fd, None)
    finally:
        os.close(fd)


def current_profile():
    now = time.monotonic()
    try:
        stamp = PROFILE_STAMP.stat().st_mtime
    except OSError:
        stamp = 0.0
    if _profile['at'] and now - _profile['at'] < PROFILE_TTL and stamp == _profile['stamp']:
        return _profile['value']
    _profile['value'] = run(['powerprofilesctl', 'get']).strip()
    _profile['at'] = now
    _profile['stamp'] = stamp
    return _profile['value']


def metrics(previous=None):
    raw = read('/proc/stat')
    rows = cpu_lines(raw)
    if 'cpu' not in rows:
        raise RuntimeError('Kernel CPU telemetry unavailable')
    ts = time.time()
    monotonic = time.monotonic()
    old = previous.get('raw', {}) if previous else {}
    elapsed = monotonic - previous['monotonic'] if previous else 0
    busy, breakdown = usage(rows['cpu'], old.get('cpu'))
    core_temp, core_temps, sensors = temperatures()
    cores = []
    for name in sorted((k for k in rows if k != 'cpu'), key=lambda k: int(k[3:])):
        index = int(name[3:])
        core_busy, _ = usage(rows[name], old.get(name))
        core_id = read_int(SYS_CPU / f'cpu{index}/topology/core_id')
        if core_id is not None and core_id < 0:
            core_id = None
        package_id = read_int(SYS_CPU / f'cpu{index}/topology/physical_package_id')
        cores.append({'id': index, 'core': core_id, 'package': package_id, 'busy': core_busy,
                      'freq': read_int(SYS_CPU / f'cpu{index}/cpufreq/scaling_cur_freq'),
                      'temp': core_temps.get((package_id, str(core_id)), core_temps.get((None, str(core_id))))})
    threads = len(cores) or 1
    physical = len({(c['package'], c['core']) if c['core'] is not None else ('cpu', c['id']) for c in cores}) or threads
    counters = {}
    for line in raw.splitlines():
        parts = line.split()
        if parts and parts[0] in ('ctxt', 'processes', 'procs_running', 'procs_blocked', 'intr'):
            try:
                counters[parts[0]] = int(parts[1])
            except (ValueError, IndexError):
                continue
    rates = {k: max(0, counters.get(k, 0) - previous.get('counters', {}).get(k, counters.get(k, 0))) / elapsed if elapsed > 0 else 0 for k in ('ctxt', 'processes', 'intr')}
    load = read('/proc/loadavg').split()
    try:
        load1, load5, load15 = (float(v) for v in load[:3])
    except ValueError:
        load1 = load5 = load15 = 0.0
    psi = {}
    for line in read('/proc/pressure/cpu').splitlines():
        try:
            parts = line.split()
            if not parts:
                continue
            psi[parts[0]] = {k: float(v) for k, v in (s.split('=') for s in parts[1:])}
        except (ValueError, IndexError):
            continue
    freq = frequency()
    known = [c['freq'] for c in cores if c['freq']]
    freq['avg'] = sum(known) / len(known) if known else None
    freq['peak'] = max(known) if known else None
    _package_throttle = read_int(SYS_CPU / 'cpu0/thermal_throttle/package_throttle_count')
    _core_files = list(SYS_CPU.glob('cpu*/thermal_throttle/core_throttle_count'))
    _core_vals = [read_int(f) for f in _core_files]
    _core_throttle = sum(_core_vals) if _core_files and all(v is not None for v in _core_vals) else None
    throttle = {'package': _package_throttle, 'core': _core_throttle}
    # Both counters are cumulative since boot, so the totals only ever grow and
    # say nothing about now: a laptop that throttled once this morning would
    # read as throttling forever. The panel scores the rate instead, smoothed
    # over roughly half a minute so a single event does not spike it to
    # twenty a minute on a three-second tick.
    # Missing throttle files report None rather than 0 so the panel can tell
    # "no sensor" apart from "no throttling".
    prev_thr = previous.get('throttle') if previous else None
    if prev_thr and elapsed > 0 and throttle['package'] is not None and throttle['core'] is not None:
        grew = max(0, (throttle['package'] - (prev_thr.get('package') or 0)) + (throttle['core'] - (prev_thr.get('core') or 0)))
        instant = grew / elapsed * 60
        before = prev_thr.get('perMinute')
        throttle['perMinute'] = instant if before is None else before + (instant - before) * 0.1
    else:
        throttle['perMinute'] = None
    watts = None
    energy = read_int('/sys/class/powercap/intel-rapl:0/energy_uj')
    if energy is not None and previous and previous.get('energy') is not None and elapsed > 0:
        delta = energy - previous['energy']
        if delta < 0:
            limit = read_int('/sys/class/powercap/intel-rapl:0/max_energy_range_uj')
            if limit and 0 <= energy < limit and 0 <= previous['energy'] < limit:
                delta += limit
        if delta >= 0:
            watts = delta / 1e6 / elapsed
    model = ''
    for line in read('/proc/cpuinfo').splitlines():
        if line.startswith('model name'):
            model = line.partition(':')[2].strip()
            break
    return {'ts': ts, 'monotonic': monotonic, 'warm': bool(old.get('cpu')), 'busyPct': busy, 'idlePct': 100 - busy, 'breakdown': breakdown, 'cores': cores,
            'threads': threads, 'physical': physical, 'model': model[:80],
            'load': [load1, load5, load15], 'loadPct': load1 / threads * 100,
            'running': counters.get('procs_running', 0), 'blocked': counters.get('procs_blocked', 0),
            'psi': psi, 'rates': rates, 'counters': counters, 'freq': freq, 'temp': core_temp, 'sensors': sensors,
            'throttle': throttle, 'watts': watts, 'energy': energy,
            'profile': current_profile(),
            'uptime': float((read('/proc/uptime').split() or ['0'])[0]), 'raw': rows}

def db_open():
    db = sqlite3.connect(STATE / 'history.sqlite3', timeout=1)
    try:
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, busy REAL, temp REAL, psi REAL, load REAL, boot TEXT)')
        return db
    except BaseException:
        db.close()
        raise

def record(db, m):
    db.execute('INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?)', (m['ts'], m['busyPct'], m['temp'], m['psi'].get('some', {}).get('avg10', 0), m['loadPct'], read('/proc/sys/kernel/random/boot_id').strip()))
    db.execute('DELETE FROM samples WHERE ts < ?', (m['ts']-7*86400,))
    db.commit()

def history(db, seconds, now=None):
    now = time.time() if now is None else now
    bucket = max(15, seconds/240)
    # Boot is part of each bucket; never connect a line across a reboot.
    rows = db.execute('SELECT MIN(ts), AVG(busy), MAX(busy), AVG(NULLIF(temp, 0)), MAX(psi), COUNT(*), boot FROM samples WHERE ts>=? AND ts<=? GROUP BY CAST(ts/? AS INTEGER), boot ORDER BY MIN(ts)', (now-seconds, now, bucket)).fetchall()
    return {'seconds': seconds, 'bucket': bucket, 'now': now, 'points': rows, 'count': sum(r[5] for r in rows), 'peak': max((r[2] for r in rows), default=0)}

# State files fall into two classes, and a symlink means a different thing to
# each. Replaced files are written with tempfile.mkstemp and Path.replace():
# rename(2) does not follow a symlink at the destination, so it replaces the
# link itself rather than writing through it. Refusing there would cost a
# deliberate dotfiles arrangement its setup and buy nothing atomic() has not
# already bought. snapshot.tmp is the fixed name an older release wrote to; it
# is listed so an existing one is repaired rather than left at its old mode.
REPLACED_STATE = ('snapshot.json', 'history.json', 'snapshot.tmp')
# Opened in place, by path, so a symlink is genuinely followed and written
# through: sqlite opens the database and its sidecars, and the two locks and
# the flush stamp are opened directly.
IN_PLACE_STATE = ('history.sqlite3', 'history.sqlite3-wal', 'history.sqlite3-shm',
                  'history.sqlite3-journal', 'collector.lock', 'flush.lock', 'last-flush')


def inspect_state(directory, name):
    """Vet one state file without following a link, repairing its mode.

    Returns None when the file is absent or fine, and a reason otherwise. The
    caller decides what an unsafe file costs, because that differs by file.
    """
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     dir_fd=directory)
    except FileNotFoundError:
        return None
    except OSError as e:
        # O_NOFOLLOW reports a symlink as ELOOP. Say what it is rather than
        # letting a bare errno reach the reader.
        return 'is a symlink' if e.errno == errno.ELOOP else str(e)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return 'is not a regular file'
        if info.st_uid != os.getuid():
            return 'is owned by another user'
        if info.st_nlink != 1:
            return 'has more than one hard link'
        os.fchmod(fd, 0o600)
        return None
    finally:
        os.close(fd)


def prepare_state(strict=True):
    """Make the state directory private and vet the files in it.

    Returns {name: reason} for files that are not safe to write. Ownership and
    O_NOFOLLOW on the directory itself are unconditional either way.

    strict=True is the interactive path -- snapshot, focus, flush -- where a
    person is waiting on the answer and an unsafe in-place file should stop
    them with a message. The daemon passes strict=False and decides per file:
    the unit is Restart=on-failure, so raising here would turn one actionable
    problem into an endless five-second restart cycle.
    """
    # The README promises a 0700 directory of 0600 files. mkdir's mode applies
    # only when it creates the directory, so an existing state directory, or a
    # file left behind by an older release, keeps whatever mode it already had.
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    unsafe = {}
    try:
        if os.fstat(directory).st_uid != os.getuid():
            raise RuntimeError('CPU Pulse state directory is not owned by this user.')
        os.fchmod(directory, 0o700)
        for name in REPLACED_STATE:
            reason = inspect_state(directory, name)
            if reason:
                unsafe[name] = reason
        for name in IN_PLACE_STATE:
            reason = inspect_state(directory, name)
            if reason:
                if strict:
                    raise RuntimeError('Unsafe CPU Pulse state file: ' + name + ' ' + reason)
                unsafe[name] = reason
    finally:
        os.close(directory)
    return unsafe

# History ranges served to the panel; keep in sync with Model.js RANGES.
HISTORY_RANGES = (3600, 86400, 604800)

def atomic(name, value):
    # A fixed .tmp name inherits whatever mode a previous interrupted write
    # left on it; mkstemp always creates a fresh owner-only file.
    path = STATE / name
    payload = json.dumps(value, separators=(',', ':'), ensure_ascii=True, allow_nan=False)
    fd, filename = tempfile.mkstemp(prefix='.' + name + '.', suffix='.tmp', dir=STATE)
    tmp = Path(filename)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        tmp.replace(path)
        dir_fd = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        tmp.unlink(missing_ok=True)

# ---- demand-driven process scanning ---------------------------------------
# The per-process walk below is essentially the entire cost of this daemon.
# Measured on an idle machine: the scan runs 0.29 s every 9 s (~3.3% of a core)
# while the readings it sits beside cost 0.000 s. Its only consumer is one tab
# in the panel, so scanning while nobody has that tab open spends a permanent
# slice of a core building a table that is thrown away unread.
#
# The panel refreshes `want-processes` while the tab is on screen. No marker,
# or a stale one, means nothing is looking and the walk is skipped. History is
# unaffected: it is recorded from the metrics before the process table is ever
# attached.
WANT_PROCESSES = STATE / 'want-processes'
WANT_TTL = 30


def processes_wanted():
    try:
        return time.time() - WANT_PROCESSES.stat().st_mtime < WANT_TTL
    except OSError:
        return False


def daemon():
    # prepare_state() still refuses an unsafe state directory outright --
    # ownership and O_NOFOLLOW on the directory itself are unconditional even
    # when strict=False. That refusal must not escape as an exception: the
    # unit is Restart=on-failure, so exiting nonzero here turns one actionable
    # problem (a symlinked or foreign-owned state directory) into an endless
    # five-second restart cycle. Report it and stop quietly instead, the same
    # way an unsafe collector.lock below does.
    try:
        unsafe = prepare_state(strict=False)
    except (OSError, RuntimeError) as e:
        print(f'CPU Pulse: not starting, unsafe state directory: {e}', flush=True)
        return
    # collector.lock is opened by path and is the first thing this function
    # touches, so an unsafe one cannot be worked around. Return rather than
    # raise: the unit is Restart=on-failure, so exiting zero leaves one clear
    # message in the journal instead of an endless five-second restart cycle.
    if 'collector.lock' in unsafe:
        print('CPU Pulse: not starting, collector.lock ' + unsafe['collector.lock'], flush=True)
        return
    # An unsafe database costs history, not the whole recorder. This is the
    # isolation the snapshot loop already applies to a corrupt database: keep
    # publishing current CPU, and say in the dashboard why history stopped.
    blocked = sorted(n for n in unsafe if n.startswith('history.sqlite3'))
    warned = sorted(n for n in unsafe if not n.startswith('history.sqlite3'))
    with (STATE / 'collector.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        db = None
        previous = None
        ticks = None
        last_history = last_procs = 0
        was_wanted = False
        rows = []
        errors = {}
        if blocked:
            errors['history'] = '; '.join(n + ' ' + unsafe[n] for n in blocked)
            print('CPU Pulse history: ' + errors['history'], flush=True)
        if warned:
            # Replaced by rename(2), so nothing is written through the link.
            # Still worth surfacing: the reader chose that layout or did not.
            errors['state'] = '; '.join(n + ' ' + unsafe[n] for n in warned)
            print('CPU Pulse state: ' + errors['state'], flush=True)
        try:
            while True:
                start = time.monotonic()
                try:
                    m = metrics(previous)
                    if m['warm'] and start-last_history >= 15 and not blocked:
                        last_history = start
                        try:
                            if db is None:
                                db = db_open()
                            record(db, m)
                            atomic('history.json', {str(s): history(db, s, m['ts']) for s in HISTORY_RANGES})
                            errors.pop('history', None)
                        except (OSError, sqlite3.Error, RuntimeError, ValueError) as e:
                            errors['history'] = str(e)
                            print(f'CPU Pulse history: {type(e).__name__}: {e}', flush=True)
                            if db is not None:
                                db.close()
                                db = None
                    wanted = processes_wanted()
                    if wanted and (start-last_procs >= 9 or not was_wanted):
                        last_procs = start
                        try:
                            rows, ticks = hogs(ticks, m['monotonic'])
                            errors.pop('processes', None)
                        except (OSError, RuntimeError, ValueError) as e:
                            rows = []
                            errors['processes'] = str(e)
                            print(f'CPU Pulse processes: {type(e).__name__}: {e}', flush=True)
                    elif not wanted:
                        rows = []
                    was_wanted = wanted
                    m['hogs'] = rows
                    m['collectorErrors'] = dict(errors)
                    if m['warm']:
                        atomic('snapshot.json', m)
                    previous = m
                except (OSError, sqlite3.Error, RuntimeError, ValueError) as e:
                    print(f'CPU Pulse: {type(e).__name__}: {e}', flush=True)
                time.sleep(max(0.2, 3-(time.monotonic()-start)))
        finally:
            if db is not None:
                db.close()

def focus(pid, start):
    # Re-read identity and routing on click; an old snapshot cannot focus a
    # recycled PID or run a command supplied by a window title.
    p = process(pid)
    if not p or p['start'] != start or Path(f'/proc/{pid}').stat().st_uid != os.getuid():
        raise RuntimeError('Process exited or identity changed. Refresh the list.')
    target = target_for(p, all_processes(), clients())
    if not target:
        raise RuntimeError('No existing window or attached session for this process.')
    # Routing may take seconds. Reject a PID recycled while it was being resolved.
    current = process(pid)
    if not current or current['start'] != start or Path(f'/proc/{pid}').stat().st_uid != os.getuid():
        raise RuntimeError('Process exited or identity changed. Refresh the list.')
    host = target.get('host', {})
    # The socket was valid when the scan read it; re-check at use. A stale
    # or replaced path degrades to plain window focus, not a failed click.
    if host.get('socket') and not owned_socket(host['socket']):
        host = {}
    if host.get('kind') == 'herdr':
        for kind, pattern in [('workspace', r'w[\w-]{1,32}'), ('tab', r'w[\w-]{1,32}:t[\w-]{1,32}'), ('pane', r'w[\w-]{1,32}:p[\w-]{1,32}')]:
            value = host.get(kind, '')
            if not re.fullmatch(pattern, value, re.ASCII):
                continue
            request = {'id': 'cpu-pulse:'+kind, 'method': kind+'.focus', 'params': {kind+'_id': value}}
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(2)
                s.connect(host['socket'])
                s.sendall((json.dumps(request)+'\n').encode())
                reply = b''
                while b'\n' not in reply and len(reply) < 65536:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    reply += chunk
                response = json.loads(reply.split(b'\n')[0])
                if response.get('id') != request['id'] or 'error' in response or 'result' not in response:
                    raise RuntimeError('Herdr could not focus this pane.')
    elif host.get('kind') == 'tmux':
        prefix = ['tmux', '-S', host['socket']]
        for cmd in [['select-window', '-t', host['pane']], ['select-pane', '-t', host['pane']], ['switch-client', '-c', host['client'], '-t', host['pane']]]:
            result = subprocess.run(prefix+cmd, capture_output=True, timeout=2)
            if result.returncode:
                raise RuntimeError('tmux could not focus this pane.')
    version = run(['hyprctl', 'version', '-j'])
    try:
        v = json.loads(version)
        match = re.search(r'(\d+)\.(\d+)', v.get('tag', v.get('version', '')))
        lua = bool(match and (int(match[1]), int(match[2])) >= (0, 56))
    except (ValueError, TypeError):
        lua = False
    addr = target['address']
    args = ['hyprctl', 'dispatch'] + ([f'hl.dsp.focus({{ window = "address:{addr}" }})'] if lua else ['focuswindow', 'address:'+addr])
    response = run(args)
    if not response or 'error' in response.lower():
        raise RuntimeError('Window focus failed; the window may have closed.')
    return {'message': 'Focused '+p['name']}

def profile(name):
    # power-profiles-daemon applies the change through polkit as the session
    # user. It is reversible from the same card, and it never touches
    # frequencies, governors, or processes directly.
    if name not in PROFILES:
        raise RuntimeError('Unknown power profile.')
    current = run(['powerprofilesctl', 'get']).strip()
    if not current:
        raise RuntimeError('power-profiles-daemon is not available.')
    if current == name:
        return {'message': 'Power profile is already '+name+'.'}

    def invalidate():
        # The daemon caches the profile; touching this tells it to re-read on
        # its next tick instead of up to PROFILE_TTL later.
        try:
            STATE.mkdir(parents=True, exist_ok=True)
            touch_marker(PROFILE_STAMP)
        except OSError:
            pass
    try:
        result = subprocess.run(['powerprofilesctl', 'set', name], capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError('powerprofilesctl did not respond.')
    if result.returncode:
        raise RuntimeError('Profile change refused: '+(result.stderr.strip().splitlines() or ['no reason given'])[-1][:120])
    invalidate()
    return {'message': 'Power profile: '+current+' → '+name+'. The clock and temperature will settle over the next few samples.'}

def visit(link):
    # The panel names a link, it never supplies a URL. Anything reaching
    # xdg-open is one of the two constants above, so a window title or a
    # tampered snapshot cannot steer the desktop's URL handler.
    url = LINKS.get(link)
    if not url:
        raise RuntimeError('Unknown link.')
    if not shutil.which('xdg-open'):
        raise RuntimeError('No xdg-open on PATH. The address is '+url)
    # xdg-open can wait on the browser it starts, so it is detached rather than
    # waited on. That means the handoff is reported, never the page opening --
    # the About tab prints both addresses in full for when it does not.
    subprocess.Popen(['xdg-open', url], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return {'message': 'Handed '+url+' to your browser.'}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['daemon', 'snapshot', 'focus', 'profile', 'visit'])
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
            # One-shot rates use a 0.5 s interval while the daemon ticks every
            # 3 s, so the two rates are measured over different windows and
            # are not directly comparable.
            first = metrics()
            time.sleep(0.5)
            value = metrics(first)
            value['hogs'] = hogs()[0]
        elif args.action == 'visit':
            value = visit(args.link)
        elif args.action == 'focus':
            if len(args.args) != 2 or not args.args[0].isdigit():
                raise RuntimeError('focus needs a PID and a start time.')
            value = focus(int(args.args[0]), args.args[1])
        else:
            if len(args.args) != 1:
                raise RuntimeError('profile needs one name.')
            value = profile(args.args[0])
        print(json.dumps(value))
    except Exception as e:
        print(json.dumps({'error': str(e)}))
        raise SystemExit(1)

if __name__ == '__main__':
    main()
