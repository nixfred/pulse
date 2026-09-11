#!/usr/bin/env python3
"""Disk Pulse: unprivileged storage telemetry, persistent history, focus-only navigation."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import stat
import subprocess
import tempfile
import threading
import time

_state_home = os.environ.get('XDG_STATE_HOME', '')
STATE = (Path(_state_home) if os.path.isabs(_state_home) else Path.home() / '.local/state') / 'disk-pulse'
ENV_KEYS = {'HERDR_ENV', 'HERDR_SOCKET_PATH', 'HERDR_WORKSPACE_ID', 'HERDR_TAB_ID', 'HERDR_PANE_ID', 'TMUX', 'TMUX_PANE', 'BOOMUX_SHELL_ID'}
# /proc/diskstats and /sys/block/*/stat count 512-byte sectors whatever the
# device's own block size is.
SECTOR = 512
SYS_BLOCK = Path('/sys/class/block')
SYS_BTRFS = Path('/sys/fs/btrfs')
# Pseudo and in-memory filesystems: never a place your files live, so never a
# row in the dashboard. Everything else that is mounted is shown.
PSEUDO_FS = {'proc', 'sysfs', 'tmpfs', 'devtmpfs', 'devpts', 'cgroup', 'cgroup2', 'pstore', 'bpf',
             'securityfs', 'debugfs', 'tracefs', 'configfs', 'fusectl', 'hugetlbfs', 'mqueue',
             'binfmt_misc', 'autofs', 'efivarfs', 'ramfs', 'nsfs', 'rpc_pipefs', 'selinuxfs',
             'squashfs', 'overlay', 'fuse.portal', 'fuse.gvfsd-fuse', 'fuse.lxcfs', 'fuse.snapfuse',
             'fuse.rofiles-fuse', 'fuse.appimagelauncherfs', 'fuse.fuse-overlayfs'}
# A network or userspace filesystem can stop answering, and statvfs then
# blocks for as long as its server takes to come back. These are measured on
# a helper thread with a deadline instead of on the sampling loop.
NETWORK_FS = {'nfs', 'nfs4', 'cifs', 'smb3', 'smbfs', '9p', 'afs', 'ceph', 'glusterfs', 'sshfs',
              'davfs', 'fuse.sshfs', 'fuse.rclone', 'fuse.davfs2', 'fuse.gcsfuse', 'fuse.s3fs'}
REMOTE_DEADLINE = 1.5
# A share that answered recently but is taking longer than the deadline this
# time is slow, not gone. It keeps its reading and its standing for this long
# before it is reported as not answering.
REMOTE_GRACE = 10.0
# Devices that are not storage of yours: compressed swap, loop-mounted
# images, the RAM disks, network block devices and optical drives.
SKIP_DISKS = ('loop', 'ram', 'zram', 'nbd', 'sr', 'fd', 'md')
BTRFS_PROFILES = ('single', 'dup', 'raid0', 'raid1', 'raid1c3', 'raid1c4', 'raid10', 'raid5', 'raid6')

def read(path):
    try:
        return Path(path).read_text(errors='replace')
    except (OSError, ValueError):
        return ''

def read_int(path, default=0):
    try:
        return int(read(path).split()[0])
    except (ValueError, IndexError):
        return default

def fields(raw):
    result = {}
    for line in raw.splitlines():
        key, _, value = line.partition(':')
        try:
            result[key] = int(value.split()[0]) * 1024
        except (ValueError, IndexError):
            pass
    return result

def run(args, timeout=2):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return p.stdout if p.returncode == 0 else ''
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return ''

class CommandBudget:
    # One scan gets one subprocess-wait budget, not one per invocation, and
    # repeated identical lookups answer from the cache.
    def __init__(self, seconds=2):
        self.deadline = time.monotonic() + seconds
        self.cache = {}

    def __call__(self, args):
        key = tuple(args)
        if key not in self.cache:
            remaining = self.deadline - time.monotonic()
            self.cache[key] = run(args, timeout=min(2, remaining)) if remaining > 0 else ''
        return self.cache[key]

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
        return {'pid': int(pid), 'start': tail[19], 'ppid': int(tail[1]),
                'name': raw[raw.index('(')+1:raw.rindex(')')][:64]}
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

def target_for(p, procs, wins, query=None):
    query = run if query is None else query
    windows = {c['pid']: c for c in wins}
    w = window_for(p['pid'], procs, windows)
    env = environment(p['pid'])
    host = {}
    # Boomux terminal titles carry an exact shell id. Focusing that existing
    # window needs no launcher and cannot create or terminate a session.
    shell = env.get('BOOMUX_SHELL_ID', '')
    if shell:
        match = [c for c in wins if str(c.get('title', '')).startswith('boomux:shell:') and str(c.get('title', '')).split(' ')[0].endswith(':' + shell)]
        if match:
            w = match[0]
    if not shell and env.get('HERDR_ENV') == '1' and env.get('HERDR_PANE_ID'):
        sock = env.get('HERDR_SOCKET_PATH') or str(Path.home() / '.config/herdr/herdr.sock')
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
        sock = env['TMUX'].rsplit(',', 2)[0]
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

def io_counters(pid):
    # read_bytes and write_bytes count what actually reached the storage
    # layer. rchar/wchar count every read() and write() including the ones the
    # page cache answered, which is not disk traffic and is not shown.
    raw = read(f'/proc/{pid}/io')
    if not raw:
        return None
    out = {}
    for line in raw.splitlines():
        key, _, value = line.partition(':')
        if key in ('read_bytes', 'write_bytes'):
            try:
                out[key] = int(value)
            except ValueError:
                return None
    return out if len(out) == 2 else None

def scan_processes():
    """Every process, with its storage counters where they are readable."""
    procs = {}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            p = process(entry.name)
            if p:
                procs[p['pid']] = p
    seen = []
    for p in procs.values():
        io = io_counters(p['pid'])
        if io is None:
            continue
        try:
            owned = Path(f"/proc/{p['pid']}").stat().st_uid == os.getuid()
        except OSError:
            continue
        seen.append((p, io, owned))
    return procs, seen

def hogs(previous=None, now=None, scan=None):
    """Top processes by storage traffic. Rate over the last scan, then lifetime.

    Only processes this user owns expose their I/O counters without
    privilege, so a root service that is thrashing the disk is invisible here
    and shows up in the drive's own numbers instead.
    """
    now = time.monotonic() if now is None else now
    previous = previous or {}
    query = CommandBudget()
    procs, seen = (scan or scan_processes)()
    wins = clients(query)
    current = {}
    live = []
    for p, io, owned in seen:
        key = (p['pid'], p['start'])
        current[key] = (now, io['read_bytes'], io['write_bytes'])
        earlier = previous.get(key)
        elapsed = now - earlier[0] if earlier else 0
        # A counter that went backwards is a recycled PID with the same start
        # tick, which cannot happen, or a kernel quirk; either way it is not
        # traffic and reads as none for one scan.
        read_rate = max(0, io['read_bytes'] - earlier[1]) / elapsed if earlier and elapsed > 0 else 0
        write_rate = max(0, io['write_bytes'] - earlier[2]) / elapsed if earlier and elapsed > 0 else 0
        if io['read_bytes'] <= 0 and io['write_bytes'] <= 0:
            continue
        live.append(dict(p, readRate=read_rate, writeRate=write_rate, readTotal=io['read_bytes'],
                         writeTotal=io['write_bytes'], owned=owned))
    live.sort(key=lambda p: (p['readRate'] + p['writeRate'], p['readTotal'] + p['writeTotal']), reverse=True)
    rows = live[:24]
    for p in rows:
        p['target'] = target_for(p, procs, wins, query) if p['owned'] else {}
    return rows, current

def unescape(text):
    # mountinfo escapes space, tab, newline and backslash as octal.
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), text)

# Kernel trees whose mounts are never a place your files live. Matched as the
# directory itself or something under it: /development is a real mount.
HIDDEN_TREES = ('/proc', '/sys', '/dev', '/run/credentials')

def hidden(mount):
    return any(mount == tree or mount.startswith(tree + '/') for tree in HIDDEN_TREES)

def physical_of(name, depth=0):
    """The physical disk under a block device: through dm and partitions."""
    if depth > 8 or not name:
        return ''
    base = SYS_BLOCK / name
    if not base.exists():
        return ''
    slaves = base / 'slaves'
    if slaves.is_dir():
        under = sorted(p.name for p in slaves.iterdir())
        if under:
            return physical_of(under[0], depth + 1)
    if (base / 'partition').exists():
        try:
            return physical_of(base.resolve().parent.name, depth + 1)
        except OSError:
            return ''
    return name

def encrypted(name, depth=0):
    """True when a LUKS mapping sits anywhere under this block device."""
    if depth > 8 or not name:
        return False
    base = SYS_BLOCK / name
    if read(base / 'dm/uuid').startswith('CRYPT-'):
        return True
    slaves = base / 'slaves'
    if slaves.is_dir():
        return any(encrypted(p.name, depth + 1) for p in slaves.iterdir())
    if (base / 'partition').exists():
        try:
            return encrypted(base.resolve().parent.name, depth + 1)
        except OSError:
            return False
    return False

def device_name(source):
    try:
        real = os.path.realpath(source)
    except (OSError, ValueError):
        return ''
    return real[5:] if real.startswith('/dev/') and (SYS_BLOCK / real[5:]).exists() else ''

def mounts(raw=None):
    """Every real filesystem, one row per device, in mount order.

    A btrfs pool mounted five times as five subvolumes is one filesystem with
    one free-space figure, so its mounts fold into one row that names the
    others. The shortest mount point leads the row.
    """
    raw = read('/proc/self/mountinfo') if raw is None else raw
    rows = {}
    order = []
    for line in raw.splitlines():
        head, sep, tail = line.partition(' - ')
        h, t = head.split(), tail.split()
        if not sep or len(h) < 6 or len(t) < 2:
            continue
        dev, mount, opts = h[2], unescape(h[4]), h[5]
        fstype, source = t[0], unescape(t[1])
        superopts = t[2] if len(t) > 2 else ''
        if fstype in PSEUDO_FS or hidden(mount):
            continue
        remote = fstype in NETWORK_FS or (fstype.startswith('fuse') and fstype != 'fuseblk')
        key = dev if not remote else dev + ':' + source
        options = set(opts.split(',')) | set(superopts.split(','))
        compress = next((o.partition('=')[2] or 'yes' for o in options if o == 'compress' or o.startswith('compress=') or o.startswith('compress-force=')), '')
        subvol = next((o[7:] for o in options if o.startswith('subvol=')), '')
        name = device_name(source) if not remote else ''
        entry = {'mount': mount, 'also': [], 'fstype': fstype, 'source': source,
                 'remote': remote, 'device': physical_of(name) if name else '',
                 'block': name, 'encrypted': encrypted(name) if name else False,
                 'readonly': 'ro' in opts.split(','), 'compress': compress, 'subvol': subvol,
                 'flags': sorted(o for o in ('ssd', 'discard', 'noatime', 'autodefrag', 'degraded') if o in options)}
        if key in rows:
            row = rows[key]
            if len(mount) < len(row['mount']):
                # The shorter path leads the row, and every per-mount fact --
                # read-only, subvolume, noatime -- comes with it. Only the
                # list of other mounts carries over.
                entry['also'] = row['also'] + [row['mount']]
                rows[key] = entry
            else:
                row['also'].append(mount)
            continue
        rows[key] = entry
        order.append(key)
    out = [rows[k] for k in order]
    for row in out:
        row['also'].sort()
    return out

class RemoteProbe:
    """statvfs on helper threads with one shared deadline, one probe per mount.

    A share that has stopped answering costs one thread that finishes when the
    server does, never a second one. Every remote mount is asked at once and
    waited for together, so twelve dead shares cost one deadline per sample,
    not twelve. The last good reading is kept and handed back, marked
    unresponsive, while a probe is pending or the latest attempt failed, so a
    hiccup never erases a capacity the reader already had.
    """
    def __init__(self):
        self.good = {}
        self.failed = set()
        self.pending = {}
        self.started = {}
        self.lock = threading.Lock()

    def _probe(self, mount):
        # Whatever the probe raises, the mount must leave the pending set, or
        # it would be reported as hung until the recorder restarts.
        result = None
        try:
            value = os.statvfs(mount)
            result = (value.f_frsize * value.f_blocks, value.f_frsize * value.f_bavail, value.f_frsize * value.f_bfree)
        except Exception:
            result = None
        finally:
            with self.lock:
                if result is not None:
                    self.good[mount] = (time.monotonic(), result)
                    self.failed.discard(mount)
                else:
                    self.failed.add(mount)
                self.pending.pop(mount, None)

    def start(self, mount):
        with self.lock:
            if mount in self.pending:
                return
            thread = threading.Thread(target=self._probe, args=(mount,), daemon=True)
            self.pending[mount] = thread
            self.started[mount] = time.monotonic()
            try:
                thread.start()
            except Exception:
                # A thread that never started must not sit in the pending set
                # as if it were running; the next sample simply asks again.
                self.pending.pop(mount, None)
                self.failed.add(mount)

    def wait(self, mounts, deadline=None):
        """Wait for the given probes against one deadline shared by all."""
        until = time.monotonic() + (REMOTE_DEADLINE if deadline is None else deadline)
        for mount in mounts:
            with self.lock:
                thread = self.pending.get(mount)
            if thread is None:
                continue
            remaining = until - time.monotonic()
            if remaining > 0:
                thread.join(remaining)

    def read(self, mount):
        with self.lock:
            value = self.good.get(mount, (0, None))[1]
            waiting = time.monotonic() - self.started.get(mount, 0) if mount in self.pending else 0
            slow_but_known = mount in self.pending and value is not None and waiting < REMOTE_GRACE
            responsive = mount not in self.failed and (mount not in self.pending or slow_but_known)
        return value, responsive

    def __call__(self, mount, wait=True):
        self.start(mount)
        if wait:
            self.wait([mount])
        return self.read(mount)

def usage(row, probe, wait=True):
    if row['remote']:
        value, responsive = probe(row['mount'], wait)
    else:
        try:
            v = os.statvfs(row['mount'])
            value, responsive = (v.f_frsize * v.f_blocks, v.f_frsize * v.f_bavail, v.f_frsize * v.f_bfree), True
        except OSError:
            value, responsive = None, False
    row['responsive'] = responsive
    if not value:
        # Nothing known, or nothing known yet. Capacity is null, never zero:
        # zero free is a full disk, and this is not that.
        row.update(total=0, free=0, used=0, freePct=None, usedPct=None)
        return row
    total, avail, free = value
    # Used is what df reports: everything that is not free to root, which on
    # btrfs includes metadata and on ext4 the reserved blocks. Free is what
    # this user can still write, which is the number that matters.
    used = max(0, total - free)
    row.update(total=total, free=avail, used=used,
               freePct=avail / total * 100 if total else None,
               usedPct=used / total * 100 if total else None)
    return row

def scheduler_of(raw):
    m = re.search(r'\[([^\]]+)\]', raw)
    return m.group(1) if m else raw.strip()

def transport_of(name):
    if name.startswith('nvme'):
        return 'NVMe'
    if name.startswith('mmcblk'):
        return 'SD/eMMC'
    try:
        real = str((SYS_BLOCK / name).resolve())
    except OSError:
        real = ''
    if '/usb' in real:
        return 'USB'
    if '/ata' in real:
        return 'SATA'
    if name.startswith('vd'):
        return 'virtio'
    return 'disk'

def temperature_of(base):
    """Drive temperature from hwmon: NVMe controllers and SATA drivetemp."""
    for pattern in ('device/hwmon*/temp1_input', 'device/hwmon/hwmon*/temp1_input'):
        for path in sorted(base.glob(pattern)):
            raw = read(path).strip()
            if not raw:
                continue
            try:
                value = int(raw) / 1000
            except ValueError:
                continue
            folder = path.parent
            limit = read_int(folder / 'temp1_max', 0)
            crit = read_int(folder / 'temp1_crit', 0)
            return value, limit / 1000 if limit > 0 else None, crit / 1000 if crit > 0 else None
    return None, None, None

def disk_stat(base):
    try:
        raw = [int(v) for v in read(base / 'stat').split()]
    except ValueError:
        return None
    # reads, merges, sectors, ms, writes, merges, sectors, ms, in flight,
    # ms doing I/O, weighted ms, then discards and flushes on newer kernels.
    return raw if len(raw) >= 11 else None

def disks(previous=None, now=None):
    """Every physical disk with its rates over the interval since previous."""
    now = time.monotonic() if now is None else now
    previous = previous or {}
    out = []
    for base in sorted(SYS_BLOCK.iterdir()):
        name = base.name
        if name.startswith(SKIP_DISKS) or not (base / 'device').exists() or (base / 'partition').exists():
            continue
        size = read_int(base / 'size') * SECTOR
        if size <= 0:
            continue
        counters = disk_stat(base)
        if counters is None:
            continue
        rates = {'read': 0, 'write': 0, 'readIops': 0, 'writeIops': 0, 'awaitRead': None, 'awaitWrite': None, 'util': 0, 'queue': 0}
        earlier = previous.get(name)
        if earlier:
            elapsed = now - earlier['monotonic']
            delta = [a - b for a, b in zip(counters, earlier['counters'])]
            # A reset or a wrapped counter reads as no traffic for one sample
            # rather than as a negative or an absurd spike. Field 9 (index 8)
            # is requests in flight, a gauge that falls as work completes; it
            # is the one field that may legitimately go down and must not be
            # mistaken for a reset, or every quiet moment erases a sample.
            if elapsed > 0 and all(d >= 0 for i, d in enumerate(delta[:11]) if i != 8):
                rates['read'] = delta[2] * SECTOR / elapsed
                rates['write'] = delta[6] * SECTOR / elapsed
                rates['readIops'] = delta[0] / elapsed
                rates['writeIops'] = delta[4] / elapsed
                rates['awaitRead'] = delta[3] / delta[0] if delta[0] else None
                rates['awaitWrite'] = delta[7] / delta[4] if delta[4] else None
                # ms doing I/O over wall time. A multi-queue device can report
                # more than 100%; the reading is capped where the scale ends.
                rates['util'] = min(100, delta[9] / (elapsed * 1000) * 100)
                rates['queue'] = delta[10] / (elapsed * 1000)
        inflight = read(base / 'inflight').split()
        temp, temp_max, temp_crit = temperature_of(base)
        partitions = []
        for part in sorted(base.glob(name + '*')):
            if (part / 'partition').exists():
                partitions.append({'name': part.name, 'size': read_int(part / 'size') * SECTOR})
        out.append({'name': name, 'model': ' '.join(read(base / 'device/model').split())[:48],
                    'firmware': ' '.join(read(base / 'device/firmware_rev').split())[:24],
                    'size': size, 'rotational': read_int(base / 'queue/rotational') == 1,
                    'transport': transport_of(name), 'scheduler': scheduler_of(read(base / 'queue/scheduler')),
                    'nrRequests': read_int(base / 'queue/nr_requests'),
                    'discard': read_int(base / 'queue/discard_max_bytes') > 0,
                    'writeCache': read(base / 'queue/write_cache').strip(),
                    'logicalBlock': read_int(base / 'queue/logical_block_size'),
                    'inflight': [int(v) for v in inflight[:2]] if len(inflight) >= 2 and all(v.isdigit() for v in inflight[:2]) else [0, 0],
                    'temp': temp, 'tempMax': temp_max, 'tempCrit': temp_crit,
                    'rates': rates, 'partitions': partitions,
                    'counters': counters, 'monotonic': now})
    return out

def psi():
    out = {}
    for line in read('/proc/pressure/io').splitlines():
        parts = line.split()
        try:
            out[parts[0]] = {k: float(v) for k, v in (s.split('=') for s in parts[1:])}
        except (ValueError, IndexError):
            pass
    return out

def btrfs_pools():
    """Allocation, device errors and commit timing for every mounted btrfs.

    All of it is sysfs and readable without privilege, which is more than the
    btrfs tool itself will show an ordinary user.
    """
    out = {}
    root = SYS_BTRFS
    if not root.is_dir():
        return out
    for pool in sorted(root.iterdir()):
        alloc = pool / 'allocation'
        if not alloc.is_dir():
            continue
        spaces = {}
        raw_allocated = 0
        # mixed is the fourth space, on filesystems whose data and metadata
        # share block groups; leaving it out would count those chunks as
        # unallocated and show an empty pool.
        for kind in ('data', 'metadata', 'system', 'mixed'):
            folder = alloc / kind
            if not folder.is_dir():
                continue
            # The kernel creates a profile directory when the first block
            # group of that profile appears and keeps it until unmount, so
            # after a conversion the old, empty profile is still listed.
            # Only a profile that holds bytes is current; during a
            # conversion two do, and both are named.
            present = [p for p in BTRFS_PROFILES if (folder / p).is_dir()]
            live = [p for p in present if read_int(folder / p / 'total_bytes') > 0]
            profile = '+'.join(live) if live else (present[0] if present else '')
            disk_total = read_int(folder / 'disk_total')
            raw_allocated += disk_total
            spaces[kind] = {'used': read_int(folder / 'bytes_used'), 'total': read_int(folder / 'total_bytes'),
                            'diskTotal': disk_total, 'diskUsed': read_int(folder / 'disk_used'), 'profile': profile}
        devices = []
        device_bytes = 0
        for dev in sorted((pool / 'devices').iterdir()) if (pool / 'devices').is_dir() else []:
            devices.append(dev.name)
            device_bytes += read_int(SYS_BLOCK / dev.name / 'size') * SECTOR
        errors = {}
        for info in sorted((pool / 'devinfo').iterdir()) if (pool / 'devinfo').is_dir() else []:
            for line in read(info / 'error_stats').splitlines():
                key, _, value = line.partition(' ')
                try:
                    errors[key] = errors.get(key, 0) + int(value)
                except ValueError:
                    pass
        commits = {}
        for line in read(pool / 'commit_stats').splitlines():
            key, _, value = line.partition(' ')
            try:
                commits[key] = int(value)
            except ValueError:
                pass
        out[pool.name] = {'label': read(pool / 'label').strip(), 'spaces': spaces, 'devices': devices,
                          'deviceBytes': device_bytes, 'unallocated': max(0, device_bytes - raw_allocated),
                          'globalReserve': {'size': read_int(alloc / 'global_rsv_size'), 'reserved': read_int(alloc / 'global_rsv_reserved')},
                          'errors': errors, 'errorTotal': sum(errors.values()), 'commits': commits,
                          'discardSaved': read_int(pool / 'discard/discard_bytes_saved'),
                          'features': sorted(p.name for p in (pool / 'features').iterdir()) if (pool / 'features').is_dir() else [],
                          'nodesize': read_int(pool / 'nodesize'), 'sectorsize': read_int(pool / 'sectorsize')}
    return out

def systemd_stamp(raw):
    # systemctl --timestamp=unix prints "@1757226483"; older systemd prints
    # the pretty form, which is passed through as text for the dashboard.
    value = raw.strip()
    if value.startswith('@') and value[1:].isdigit():
        return int(value[1:])
    return value or None

def trim_status(query=None):
    query = run if query is None else query
    out = {'timer': None, 'last': None, 'next': None, 'result': None}
    raw = query(['systemctl', 'show', '--timestamp=unix', 'fstrim.timer', '-p', 'LastTriggerUSec', '-p', 'NextElapseUSecRealtime', '-p', 'ActiveState'])
    if not raw:
        return out
    for line in raw.splitlines():
        key, _, value = line.partition('=')
        if key == 'ActiveState':
            out['timer'] = value.strip()
        elif key == 'LastTriggerUSec':
            out['last'] = systemd_stamp(value)
        elif key == 'NextElapseUSecRealtime':
            out['next'] = systemd_stamp(value)
    raw = query(['systemctl', 'show', 'fstrim.service', '-p', 'Result'])
    for line in raw.splitlines():
        key, _, value = line.partition('=')
        if key == 'Result':
            out['result'] = value.strip()
    return out

def variant(value):
    # busctl --json wraps every D-Bus value as {"type": ..., "data": ...}.
    if isinstance(value, dict) and set(value) == {'type', 'data'}:
        return variant(value['data'])
    if isinstance(value, list):
        return [variant(v) for v in value]
    if isinstance(value, dict):
        return {k: variant(v) for k, v in value.items()}
    return value

def bytes_string(value):
    if isinstance(value, list):
        return bytes(v for v in value if isinstance(v, int) and 0 < v < 256).decode('utf-8', 'replace')
    return str(value or '')

def busctl(args, timeout=4):
    raw = run(['busctl', '--system', '--json=short', '--timeout=' + str(timeout)] + args, timeout=timeout + 1)
    if not raw:
        return None
    try:
        return variant(json.loads(raw).get('data', []))
    except (ValueError, AttributeError):
        return None

def smart(query=None):
    """Drive health through udisks, which reads SMART for the console user.

    smartctl and nvme-cli need the device node, which is root-only; udisks
    already holds it and publishes what it read over D-Bus. Nothing here
    persists a serial number.
    """
    query = busctl if query is None else query
    objects = query(['call', 'org.freedesktop.UDisks2', '/org/freedesktop/UDisks2', 'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects'])
    if not objects or not isinstance(objects, list) or not isinstance(objects[0], dict):
        return {}
    objects = objects[0]
    drives = {}
    for path, ifaces in objects.items():
        if '/drives/' not in path or 'org.freedesktop.UDisks2.Drive' not in ifaces:
            continue
        drive = ifaces['org.freedesktop.UDisks2.Drive']
        info = {'vendor': str(drive.get('Vendor', '')).strip(), 'bus': str(drive.get('ConnectionBus', '')),
                'removable': bool(drive.get('Removable', False)), 'kind': 'none'}
        ata = ifaces.get('org.freedesktop.UDisks2.Drive.Ata')
        nvme = ifaces.get('org.freedesktop.UDisks2.NVMe.Controller')
        # udisks documents that every Smart* property is meaningless until
        # SmartUpdated is non-zero, and that some unknowns are sentinels: -1
        # for ATA sector and attribute counts, 0 for power-on time. A drive
        # that has not been read yet is reported as unread, not as healthy.
        if nvme and not (nvme.get('SmartUpdated') or 0):
            info.update(kind='none', reason='SMART not read yet')
        elif ata and ata.get('SmartSupported') and not (ata.get('SmartUpdated') or 0):
            info.update(kind='none', reason='SMART not read yet')
        elif nvme:
            kelvin = nvme.get('SmartTemperature') or 0
            warnings = nvme.get('SmartCriticalWarning') or []
            hours = nvme.get('SmartPowerOnHours') or 0
            info.update(kind='nvme', temp=round(kelvin - 273.15, 1) if kelvin else None,
                        powerOnHours=hours if hours > 0 else None, warnings=[str(w) for w in warnings],
                        selftest=str(nvme.get('SmartSelftestStatus', '')), updated=nvme.get('SmartUpdated'),
                        revision=str(nvme.get('NVMeRevision', '')))
            attrs = query(['call', 'org.freedesktop.UDisks2', path, 'org.freedesktop.UDisks2.NVMe.Controller', 'SmartGetAttributes', 'a{sv}', '0'])
            if attrs and isinstance(attrs, list) and isinstance(attrs[0], dict):
                a = attrs[0]
                info.update(percentUsed=a.get('percent_used'), spare=a.get('avail_spare'), spareThreshold=a.get('spare_thresh'),
                            totalRead=a.get('total_data_read'), totalWritten=a.get('total_data_written'),
                            powerCycles=a.get('power_cycles'), unsafeShutdowns=a.get('unsafe_shutdowns'),
                            mediaErrors=a.get('media_errors'), errorLogEntries=a.get('num_err_log_entries'),
                            busyMinutes=a.get('ctrl_busy_time'),
                            warnTemp=round(a['wctemp'] - 273.15, 1) if a.get('wctemp') else None,
                            critTemp=round(a['cctemp'] - 273.15, 1) if a.get('cctemp') else None)
        elif ata and ata.get('SmartSupported'):
            kelvin = ata.get('SmartTemperature') or 0
            seconds = ata.get('SmartPowerOnSeconds') or 0
            def known(value):
                return value if isinstance(value, int) and value >= 0 else None
            info.update(kind='ata', temp=round(kelvin - 273.15, 1) if kelvin else None,
                        powerOnHours=seconds // 3600 if seconds > 0 else None, failing=bool(ata.get('SmartFailing', False)),
                        badSectors=known(ata.get('SmartNumBadSectors')), attributesFailing=known(ata.get('SmartNumAttributesFailing')),
                        selftest=str(ata.get('SmartSelftestStatus', '')), updated=ata.get('SmartUpdated'), warnings=[])
        drives[path] = info
    out = {}
    for path, ifaces in objects.items():
        block = ifaces.get('org.freedesktop.UDisks2.Block')
        if not block or 'org.freedesktop.UDisks2.Partition' in ifaces:
            continue
        drive = str(block.get('Drive', '/'))
        if drive not in drives:
            continue
        name = bytes_string(block.get('Device')).rstrip('\0')
        if name.startswith('/dev/'):
            out[name[5:]] = drives[drive]
    return out

def metrics(previous=None, probe=None, cache=None):
    probe = probe if probe is not None else RemoteProbe()
    cache = cache if cache is not None else {}
    now = time.monotonic()
    ts = time.time()
    devices = disks({d['name']: d for d in previous['disks']} if previous else None, now)
    # A machine with no disk of its own (a container, a diskless boot) still
    # has filesystems, and a namespace with no eligible filesystem still has
    # drives and pressure. Neither empties the other.
    rows = mounts()
    for row in rows:
        if row['remote']:
            probe.start(row['mount'])
    probe.wait([row['mount'] for row in rows if row['remote']])
    filesystems = [usage(row, probe, wait=False) for row in rows]
    for fs in filesystems:
        fs['pool'] = ''
    pools = btrfs_pools()
    for uuid, pool in pools.items():
        for fs in filesystems:
            if fs['fstype'] == 'btrfs' and fs['block'] in pool['devices']:
                fs['pool'] = uuid
    health = cache.get('smart', {})
    for d in devices:
        d['smart'] = health.get(d['name'], {})
        if d['temp'] is None and d['smart'].get('temp') is not None:
            d['temp'] = d['smart']['temp']
            d['tempMax'] = d['smart'].get('warnTemp')
            d['tempCrit'] = d['smart'].get('critTemp')
    mem = fields(read('/proc/meminfo'))
    totals = {'read': sum(d['rates']['read'] for d in devices), 'write': sum(d['rates']['write'] for d in devices),
              'readIops': sum(d['rates']['readIops'] for d in devices), 'writeIops': sum(d['rates']['writeIops'] for d in devices),
              'util': max((d['rates']['util'] for d in devices), default=0)}
    return {'ts': ts, 'monotonic': now, 'warm': previous is not None, 'filesystems': filesystems, 'disks': devices,
            'rates': totals, 'psi': psi(), 'dirty': mem.get('Dirty', 0), 'writeback': mem.get('Writeback', 0),
            'btrfs': pools, 'trim': cache.get('trim', {}), 'smartAt': cache.get('smartAt')}

def public(m):
    """The snapshot as written: raw counters are for the next sample only."""
    out = dict(m)
    out['disks'] = [{k: v for k, v in d.items() if k not in ('counters', 'monotonic')} for d in m['disks']]
    out.pop('monotonic', None)
    return out

def primary_of(m):
    for fs in m['filesystems']:
        if fs['mount'] == '/':
            return fs
    return m['filesystems'][0] if m['filesystems'] else None

def drive_of(m, fs):
    for d in m['disks']:
        if fs and d['name'] == fs.get('device'):
            return d
    return max(m['disks'], key=lambda d: d['rates']['util'], default=None)

# State files fall into two classes, and a symlink means a different thing to
# each. Replaced files are written with tempfile.mkstemp and Path.replace():
# rename(2) does not follow a symlink at the destination, so it replaces the
# link itself rather than writing through it. Refusing there would cost a
# deliberate dotfiles arrangement its setup and buy nothing atomic() has not
# already bought.
REPLACED_STATE = ('snapshot.json', 'history.json')
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
            raise RuntimeError('Disk Pulse state directory is not owned by this user.')
        os.fchmod(directory, 0o700)
        for name in REPLACED_STATE:
            reason = inspect_state(directory, name)
            if reason:
                unsafe[name] = reason
        for name in IN_PLACE_STATE:
            reason = inspect_state(directory, name)
            if reason:
                if strict:
                    raise RuntimeError('Unsafe Disk Pulse state file: ' + name + ' ' + reason)
                unsafe[name] = reason
    finally:
        os.close(directory)
    return unsafe

def db_open():
    db = sqlite3.connect(STATE / 'history.sqlite3', timeout=1)
    try:
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, used REAL, read REAL, write REAL, util REAL, psi REAL, temp REAL, boot TEXT)')
        return db
    except BaseException:
        db.close()
        raise

def record(db, m):
    fs = primary_of(m)
    drive = drive_of(m, fs)
    db.execute('INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?)',
               (m['ts'], fs.get('usedPct') if fs else None, m['rates']['read'], m['rates']['write'],
                drive['rates']['util'] if drive else 0, m['psi'].get('some', {}).get('avg10', 0),
                drive['temp'] if drive else None, read('/proc/sys/kernel/random/boot_id').strip()))
    db.execute('DELETE FROM samples WHERE ts < ?', (m['ts']-7*86400,))
    db.commit()

def history(db, seconds, now=None):
    now = now or time.time()
    bucket = max(15, seconds/240)
    # Boot is part of each bucket; never connect a line across a reboot.
    rows = db.execute('SELECT MIN(ts), AVG(read), MAX(read), AVG(write), AVG(used), AVG(util), COUNT(*), boot FROM samples WHERE ts>=? AND ts<=? GROUP BY CAST(ts/? AS INTEGER), boot ORDER BY MIN(ts)', (now-seconds, now, bucket)).fetchall()
    return {'seconds': seconds, 'bucket': bucket, 'now': now, 'points': rows, 'count': sum(r[6] for r in rows),
            'peakRead': max((r[2] or 0 for r in rows), default=0), 'peakWrite': max((r[3] or 0 for r in rows), default=0)}

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
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)

def daemon():
    unsafe = prepare_state(strict=False)
    # collector.lock is opened by path and is the first thing this function
    # touches, so an unsafe one cannot be worked around. Return rather than
    # raise: the unit is Restart=on-failure, so exiting zero leaves one clear
    # message in the journal instead of an endless five-second restart cycle.
    if 'collector.lock' in unsafe:
        print('Disk Pulse: not starting, collector.lock ' + unsafe['collector.lock'], flush=True)
        return
    # An unsafe database costs history, not the whole recorder: keep
    # publishing current storage, and say in the dashboard why history stopped.
    blocked = sorted(n for n in unsafe if n.startswith('history.sqlite3'))
    warned = sorted(n for n in unsafe if not n.startswith('history.sqlite3'))
    with (STATE / 'collector.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        db = None
        previous = None
        probe = RemoteProbe()
        cache = {}
        last_history = last_procs = last_slow = 0
        rows, counters = [], {}
        errors = {}
        if blocked:
            errors['history'] = '; '.join(n + ' ' + unsafe[n] for n in blocked)
            print('Disk Pulse history: ' + errors['history'], flush=True)
        if warned:
            # Replaced by rename(2), so nothing is written through the link.
            # Still worth surfacing: the reader chose that layout or did not.
            errors['state'] = '; '.join(n + ' ' + unsafe[n] for n in warned)
            print('Disk Pulse state: ' + errors['state'], flush=True)
        try:
            while True:
                start = time.monotonic()
                try:
                    # SMART and the trim timer move slowly and cost a D-Bus
                    # round trip each; once a minute is plenty.
                    if start-last_slow >= 60 or not cache:
                        last_slow = start
                        try:
                            cache['smart'] = smart()
                            cache['smartAt'] = time.time()
                            cache['trim'] = trim_status()
                            errors.pop('health', None)
                        except (OSError, RuntimeError, ValueError) as e:
                            errors['health'] = str(e)
                            print(f'Disk Pulse health: {type(e).__name__}: {e}', flush=True)
                    m = metrics(previous, probe, cache)
                    if start-last_history >= 15 and not blocked and m['warm']:
                        last_history = start
                        try:
                            if db is None:
                                db = db_open()
                            record(db, m)
                            atomic('history.json', {str(s): history(db, s, m['ts']) for s in (3600, 86400, 604800)})
                            errors.pop('history', None)
                        except (OSError, sqlite3.Error, RuntimeError, ValueError) as e:
                            errors['history'] = str(e)
                            print(f'Disk Pulse history: {type(e).__name__}: {e}', flush=True)
                            if db is not None:
                                db.close()
                                db = None
                    if start-last_procs >= 9:
                        last_procs = start
                        try:
                            rows, counters = hogs(counters, start)
                            errors.pop('processes', None)
                        except (OSError, RuntimeError, ValueError) as e:
                            rows = []
                            errors['processes'] = str(e)
                            print(f'Disk Pulse processes: {type(e).__name__}: {e}', flush=True)
                    m['hogs'] = rows
                    m['collectorErrors'] = dict(errors)
                    atomic('snapshot.json', public(m))
                    previous = m
                except (OSError, sqlite3.Error, RuntimeError, ValueError) as e:
                    print(f'Disk Pulse: {type(e).__name__}: {e}', flush=True)
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
    procs = {int(f.name): q for f in Path('/proc').iterdir() if f.name.isdigit() for q in [process(f.name)] if q}
    target = target_for(p, procs, clients())
    if not target:
        raise RuntimeError('No existing window or attached session for this process.')
    host = target.get('host', {})
    if host.get('kind') == 'herdr':
        for kind, pattern in [('workspace', r'w[\w-]{1,32}'), ('tab', r'w[\w-]{1,32}:t[\w-]{1,32}'), ('pane', r'w[\w-]{1,32}:p[\w-]{1,32}')]:
            value = host.get(kind, '')
            if not re.fullmatch(pattern, value, re.ASCII):
                continue
            request = {'id': 'disk-pulse:'+kind, 'method': kind+'.focus', 'params': {kind+'_id': value}}
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

def flush():
    # sync is data-safe, unprivileged, and never discards a page. It can block
    # behind storage I/O; the UI runs this in a separate asynchronous process.
    with (STATE / 'flush.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('A flush is already in progress.')
        last = float(read(STATE / 'last-flush') or 0)
        if time.time()-last < 60:
            raise RuntimeError('Wait one minute between flushes.')
        before = fields(read('/proc/meminfo'))
        (STATE / 'last-flush').write_text(str(time.time()))
        started = time.monotonic()
        os.sync()
        after = fields(read('/proc/meminfo'))
        return {'message': f"Pending writes: {before.get('Dirty', 0)/1048576:.1f} → {after.get('Dirty', 0)/1048576:.1f} MiB in {time.monotonic()-started:.2f}s. Everything the kernel was holding is now on disk."}

def snapshot():
    # A one-shot reading needs two samples to carry a rate at all, for the
    # drives and for the processes alike.
    probe = RemoteProbe()
    cache = {'smart': smart(), 'smartAt': time.time(), 'trim': trim_status()}
    first = metrics(None, probe, cache)
    _, counters = hogs()
    time.sleep(1)
    m = metrics(first, probe, cache)
    m['hogs'] = hogs(counters)[0]
    return public(m)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['daemon', 'snapshot', 'focus', 'flush'])
    parser.add_argument('pid', nargs='?', type=int)
    parser.add_argument('start', nargs='?')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == 'daemon':
            daemon()
            return
        if args.action == 'snapshot':
            # A one-shot reading touches nothing: no state directory, no mode
            # repair, no dependence on a history it does not use.
            print(json.dumps(snapshot()))
            return
        prepare_state()
        value = focus(args.pid, args.start) if args.action == 'focus' else flush()
        print(json.dumps(value))
    except Exception as e:
        print(json.dumps({'error': str(e)}))
        raise SystemExit(1)

if __name__ == '__main__':
    main()
