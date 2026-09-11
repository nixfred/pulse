#!/usr/bin/env python3
"""Net Pulse: unprivileged network telemetry, persistent history, validated actions."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import time

STATE = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'net-pulse'
ENV_KEYS = {'HERDR_ENV', 'HERDR_SOCKET_PATH', 'HERDR_WORKSPACE_ID', 'HERDR_TAB_ID', 'HERDR_PANE_ID', 'TMUX', 'TMUX_PANE', 'BOOMUX_SHELL_ID'}
PROBE = '1.1.1.1'
PROBE6 = '2606:4700:4700::1111'
PROVIDERS = ('DHCP', 'Cloudflare', 'Google')
BANDS = ('auto', '2.4', '5', '6')
UUID_RE = r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
PING_WINDOW = 24
# `resolvectl status` wraps long lists onto indented continuation lines. A
# continuation can look like "fd::53", so only these labels open a new field.
RESOLVE_LABELS = {'Current Scopes', 'Protocols', 'Current DNS Server', 'DNS Servers',
                  'Fallback DNS Servers', 'DNS Domain', 'Default Route', 'DNSSEC supported',
                  'resolv.conf mode', 'Link', 'Global'}
HISTORY_INTERVAL = 15   # seconds between recorded samples; each sample stands for this long
SAMPLE_RETENTION = 7 * 86400        # full 15-second resolution, for the throughput graphs
USAGE_RETENTION = 5 * 365 * 86400   # hourly byte totals, for the data-usage tab
# Rolling windows the usage tab offers. 0 is everything ever recorded.
USAGE_RANGES = (3600, 86400, 604800, 2592000, 31536000, 0)
# Bucket widths, finest first, for a range that has no fixed one.
USAGE_LADDER = (3600, 21600, 86400, 604800, 2592000)


def read(path):
    try:
        return Path(path).read_text(errors='replace')
    except (OSError, ValueError):
        return ''


# Every command here is parsed by word, so the C locale is part of the contract.
C_LOCALE = dict(os.environ, LC_ALL='C', LANG='C')


def run(args, timeout=3):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False, env=C_LOCALE)
        return p.stdout if p.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''


def run_json(args, timeout=3):
    try:
        value = json.loads(run(args, timeout) or 'null')
        return value if isinstance(value, list) else []
    except ValueError:
        return []


def nm_split(line):
    """Split nmcli terse output; values escape ':' as '\\:'."""
    out, cur, esc = [], '', False
    for ch in line:
        if esc:
            cur += ch
            esc = False
        elif ch == '\\':
            esc = True
        elif ch == ':':
            out.append(cur)
            cur = ''
        else:
            cur += ch
    out.append(cur)
    return out


def number(text, default=None):
    m = re.search(r'-?\d+(?:\.\d+)?', str(text or ''))
    return float(m.group()) if m else default


# ----------------------------------------------------------------- counters

def netdev(raw=None):
    """Per-interface byte, packet, error and drop counters from /proc/net/dev."""
    result = {}
    for line in (raw if raw is not None else read('/proc/net/dev')).splitlines()[2:]:
        name, _, rest = line.partition(':')
        v = rest.split()
        if len(v) < 16:
            continue
        try:
            result[name.strip()] = {'rx': int(v[0]), 'rxPackets': int(v[1]), 'rxErrors': int(v[2]), 'rxDropped': int(v[3]),
                                    'tx': int(v[8]), 'txPackets': int(v[9]), 'txErrors': int(v[10]), 'txDropped': int(v[11])}
        except ValueError:
            pass
    return result


def rates(previous, current, elapsed):
    """Bytes per second per interface. Counter resets and new interfaces read zero, never negative."""
    out = {}
    for name, now in current.items():
        old = (previous or {}).get(name)
        if not old or elapsed <= 0:
            out[name] = {'rx': 0.0, 'tx': 0.0}
        else:
            out[name] = {'rx': max(0, now['rx'] - old['rx']) / elapsed, 'tx': max(0, now['tx'] - old['tx']) / elapsed}
    return out


def default_route():
    """The interface carrying the default route, and the probe address that suits it.

    IPv4 is preferred when both work; a host with only IPv6 connectivity is
    online and must not be reported as offline.
    """
    for probe in (PROBE, PROBE6):
        for r in run_json(['ip', '-j', 'route', 'get', probe]):
            if isinstance(r, dict) and r.get('dev'):
                return {'iface': r['dev'], 'gateway': r.get('gateway', ''), 'source': r.get('prefsrc', ''), 'probe': probe}
    for r in run_json(['ip', '-j', 'route']):
        if isinstance(r, dict) and r.get('dst') == 'default' and r.get('dev'):
            return {'iface': r['dev'], 'gateway': r.get('gateway', ''), 'source': r.get('prefsrc', ''),
                    'probe': PROBE6 if ':' in str(r.get('gateway', '')) else PROBE}
    return {}


def routes():
    out = []
    for r in run_json(['ip', '-j', 'route']):
        if isinstance(r, dict) and r.get('dev'):
            out.append({'dst': r.get('dst', ''), 'dev': r['dev'], 'gateway': r.get('gateway', ''), 'metric': r.get('metric', 0), 'protocol': r.get('protocol', '')})
    return out[:12]


def iface_kind(name):
    base = Path('/sys/class/net') / name
    if name == 'lo':
        return 'loopback'
    if (base / 'wireless').exists():
        return 'wifi'
    if (base / 'tun_flags').exists():
        return 'tunnel'
    if (base / 'bridge').exists():
        return 'bridge'
    if (base / 'device').exists():
        return 'ethernet'
    return 'virtual'


def link_info(name):
    base = Path('/sys/class/net') / name
    speed = number(read(base / 'speed'))
    duplex = read(base / 'duplex').strip()
    driver = ''
    try:
        driver = os.path.basename(os.readlink(base / 'device/driver'))
    except OSError:
        pass
    return {'speed': speed if speed is not None and speed > 0 else None, 'duplex': duplex if duplex in ('full', 'half') else '',
            'carrier': read(base / 'carrier').strip() == '1', 'driver': driver}


def addresses():
    out = {}
    for entry in run_json(['ip', '-j', 'addr']):
        if not isinstance(entry, dict) or not entry.get('ifname'):
            continue
        a4, a6 = [], []
        for a in entry.get('addr_info', []):
            text = f"{a.get('local', '')}/{a.get('prefixlen', '')}"
            if a.get('family') == 'inet':
                a4.append(text)
            elif a.get('family') == 'inet6' and a.get('scope') != 'link':
                a6.append(text)
        out[entry['ifname']] = {'mac': entry.get('address', ''), 'mtu': entry.get('mtu', 0), 'operstate': entry.get('operstate', ''),
                                'up': 'UP' in entry.get('flags', []), 'addrs4': a4, 'addrs6': a6}
    return out


# ----------------------------------------------------------------- wifi

def parse_bitrate(text):
    rate = number(text)
    gen = 'Wi-Fi 7' if 'EHT' in text else 'Wi-Fi 6' if 'HE' in text else 'Wi-Fi 5' if 'VHT' in text else 'Wi-Fi 4' if 'MCS' in text else 'legacy'
    return {'mbit': rate, 'mode': ' '.join(text.split()[2:])[:40], 'generation': gen}


def wifi_link(name, link=None, station=None, info=None):
    link = link if link is not None else run(['iw', 'dev', name, 'link'])
    if not link.startswith('Connected to'):
        return {}
    station = station if station is not None else run(['iw', 'dev', name, 'station', 'dump'])
    info = info if info is not None else run(['iw', 'dev', name, 'info'])
    kv = {}
    for line in (link + '\n' + station).splitlines():
        k, sep, v = line.strip().partition(':')
        if sep and k.strip() not in kv:
            kv[k.strip()] = v.strip()
    bssid = re.search(r'Connected to ([0-9a-f:]{17})', link)
    chan = re.search(r'channel (\d+) \((\d+) MHz\), width: (\d+) MHz', info)
    txp = re.search(r'txpower ([\d.]+) dBm', info)
    rx = parse_bitrate(kv.get('rx bitrate', ''))
    tx = parse_bitrate(kv.get('tx bitrate', ''))
    signal = number(kv.get('signal'))
    return {'ssid': kv.get('SSID', ''), 'bssid': bssid.group(1) if bssid else '', 'freq': number(kv.get('freq')),
            'channel': int(chan.group(1)) if chan else None, 'width': int(chan.group(3)) if chan else None,
            'signal': signal, 'signalAvg': number(kv.get('signal avg')), 'rxBitrate': rx['mbit'], 'txBitrate': tx['mbit'],
            'rxMode': rx['mode'], 'txMode': tx['mode'], 'generation': tx['generation'] if tx['mbit'] else rx['generation'],
            'txPower': number(txp.group(1)) if txp else None, 'retries': int(number(kv.get('tx retries'), 0)), 'failed': int(number(kv.get('tx failed'), 0)),
            'beaconLoss': int(number(kv.get('beacon loss'), 0)), 'connectedSeconds': int(number(kv.get('connected time'), 0)),
            'rxBytes': int(number(kv.get('rx bytes'), 0)), 'txBytes': int(number(kv.get('tx bytes'), 0)),
            'quality': max(0, min(100, (signal + 100) * 2)) if signal is not None else None}


def band_for(mhz):
    if mhz is None:
        return ''
    if 2400 <= mhz < 2500:
        return '2.4 GHz'
    if 4900 <= mhz < 5925:
        return '5 GHz'
    if 5925 <= mhz < 7125:
        return '6 GHz'
    if 57000 <= mhz < 71000:
        return '60 GHz'
    return f'{mhz / 1000:.1f} GHz'


def wifi_list(raw=None):
    """Nearby networks grouped by SSID, strongest access point first."""
    raw = raw if raw is not None else run(['nmcli', '-t', '-f', 'IN-USE,BSSID,SSID,MODE,CHAN,FREQ,RATE,BANDWIDTH,SIGNAL,SECURITY', 'dev', 'wifi', 'list', '--rescan', 'no'], 5)
    groups = {}
    for line in raw.splitlines():
        f = nm_split(line)
        if len(f) < 10:
            continue
        freq = number(f[5])
        row = {'inUse': f[0].strip() == '*', 'bssid': f[1], 'ssid': f[2], 'mode': f[3], 'channel': int(number(f[4], 0)), 'freq': freq,
               'band': band_for(freq), 'rate': number(f[6], 0), 'width': int(number(f[7], 0)), 'signal': int(number(f[8], 0)), 'security': f[9].strip() or 'Open'}
        key = row['ssid']
        g = groups.setdefault(key, {'ssid': key, 'hidden': key == '', 'aps': 0, 'inUse': False, 'bands': [], 'security': row['security'], 'best': None})
        g['aps'] += 1
        g['inUse'] = g['inUse'] or row['inUse']
        if row['band'] and row['band'] not in g['bands']:
            g['bands'].append(row['band'])
        if row['inUse'] or g['best'] is None or (not g['best']['inUse'] and row['signal'] > g['best']['signal']):
            g['best'] = row
    out = []
    for g in groups.values():
        b = g.pop('best')
        g.update({'bssid': b['bssid'], 'channel': b['channel'], 'freq': b['freq'], 'band': b['band'], 'rate': b['rate'], 'width': b['width'], 'signal': b['signal'], 'security': b['security']})
        out.append(g)
    out.sort(key=lambda g: (not g['inUse'], -g['signal'], g['ssid']))
    return out


def band_status(raw=None):
    kv = {}
    for line in (raw if raw is not None else run(['omarchy-network-band'], 5)).splitlines():
        k, sep, v = line.partition('\t')
        if sep:
            kv[k.strip()] = v.strip()
    return {'band': kv.get('band', ''), 'selected': kv.get('selected', 'auto'), 'available': kv.get('available', '').split()}


# ----------------------------------------------------------------- NetworkManager

def nm_devices(raw=None):
    out = {}
    for line in (raw if raw is not None else run(['nmcli', '-t', '-f', 'DEVICE,TYPE,STATE,CONNECTION,CON-UUID', 'dev', 'status'])).splitlines():
        f = nm_split(line)
        if len(f) >= 5:
            out[f[0]] = {'type': f[1], 'state': f[2], 'connection': f[3], 'uuid': f[4] if re.fullmatch(UUID_RE, f[4]) else ''}
    return out


def nm_connection(uuid, raw=None):
    if not re.fullmatch(UUID_RE, uuid):
        return {}
    fields = 'connection.id,connection.type,connection.autoconnect,connection.metered,ipv4.method,ipv6.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.ignore-auto-dns,802-11-wireless.band,802-3-ethernet.mtu,802-3-ethernet.wake-on-lan'
    raw = raw if raw is not None else run(['nmcli', '-t', '-f', fields, 'con', 'show', 'uuid', uuid])
    kv = {}
    for line in raw.splitlines():
        parts = nm_split(line)
        if len(parts) >= 2:
            kv[parts[0].strip()] = ':'.join(parts[1:]).strip()
    return {'uuid': uuid, 'name': kv.get('connection.id', ''), 'type': kv.get('connection.type', ''), 'autoconnect': kv.get('connection.autoconnect', '') == 'yes',
            'metered': kv.get('connection.metered', ''), 'method4': kv.get('ipv4.method', ''), 'method6': kv.get('ipv6.method', ''),
            'addresses4': kv.get('ipv4.addresses', ''), 'gateway4': kv.get('ipv4.gateway', ''), 'dns4': kv.get('ipv4.dns', ''),
            'ignoreAutoDns': kv.get('ipv4.ignore-auto-dns', '') == 'yes', 'band': kv.get('802-11-wireless.band', ''),
            'ethMtu': kv.get('802-3-ethernet.mtu', ''), 'wakeOnLan': kv.get('802-3-ethernet.wake-on-lan', '')}


def nm_saved(raw=None):
    """Saved profiles, so a disconnected device can still offer a way back."""
    out = []
    for line in (raw if raw is not None else run(['nmcli', '-t', '-f', 'UUID,NAME,TYPE,DEVICE', 'con', 'show'])).splitlines():
        f = nm_split(line)
        if len(f) >= 4 and re.fullmatch(UUID_RE, f[0]):
            out.append({'uuid': f[0], 'name': f[1], 'type': f[2], 'device': f[3]})
    return out


def profiles_for(saved, name, kind):
    """Profiles that could be activated on this device: bound to it, or unbound and of its type."""
    family = {'ethernet': '802-3-ethernet', 'wifi': '802-11-wireless'}.get(kind, '')
    return [p for p in saved if p['device'] == name or (not p['device'] and family and p['type'] == family)][:4]


def nm_general(raw=None):
    f = nm_split((raw if raw is not None else run(['nmcli', '-t', '-f', 'STATE,CONNECTIVITY,WIFI,WIFI-HW', 'general'])).strip())
    if len(f) < 4:
        return {'state': 'unknown', 'connectivity': 'unknown', 'wifi': None, 'wifiHardware': None}
    return {'state': f[0], 'connectivity': f[1], 'wifi': f[2] == 'enabled', 'wifiHardware': f[3] == 'enabled'}


def dns_provider():
    value = run(['omarchy-dns'], 5).strip()
    return value if value in PROVIDERS + ('Custom',) else (value[:24] or 'Unknown')


def resolve_status(raw=None):
    """systemd-resolved servers per link, from `resolvectl status`."""
    raw = raw if raw is not None else run(['resolvectl', 'status'], 5)
    links, block, key = [], None, ''
    for line in raw.splitlines():
        head = re.match(r'^(Global|Link \d+ \(([^)]+)\))\s*$', line.strip())
        if head:
            block = {'name': head.group(2) or 'Global', 'current': '', 'servers': [], 'domains': [], 'defaultRoute': False, 'dnssec': '', 'protocols': ''}
            links.append(block)
            key = ''
            continue
        if block is None:
            continue
        m = re.match(r'^\s*([A-Za-z][A-Za-z .]*?):\s?(.*)$', line)
        if m and m.group(1).strip() in RESOLVE_LABELS:
            key, value = m.group(1).strip(), m.group(2).strip()
        else:
            value = line.strip()
        if not key or not value:
            continue
        if key == 'Current DNS Server':
            block['current'] = value
        elif key in ('DNS Servers', 'Fallback DNS Servers'):
            block['servers'] += value.split()
        elif key == 'DNS Domain':
            block['domains'] += value.split()
        elif key == 'Default Route':
            block['defaultRoute'] = value == 'yes'
        elif key == 'Protocols':
            block['protocols'] = value
            sec = re.search(r'DNSSEC=(\S+)', value)
            block['dnssec'] = sec.group(1) if sec else ''
    return links


# ----------------------------------------------------------------- sockets and TCP

def peer_host(peer):
    peer = peer.strip()
    if peer.startswith('['):
        host = peer[1:peer.find(']')]
    else:
        host = peer.rsplit(':', 1)[0] if peer.count(':') == 1 else peer
    return host.split('%')[0]


def host_kind(host):
    if host in ('127.0.0.1', '::1', 'localhost'):
        return 'loopback'
    parts = host.split('.')
    if (parts[0] == '100' and len(parts) == 4 and parts[1].isdigit() and 64 <= int(parts[1]) <= 127) or host.startswith('fd7a:115c:a1e0'):
        return 'tailnet'
    if host.startswith(('10.', '192.168.', 'fd', 'fe80', '169.254.')) or re.match(r'^172\.(1[6-9]|2\d|3[01])\.', host):
        return 'LAN'
    return 'internet'


def process(pid):
    raw = read(f'/proc/{pid}/stat')
    if not raw:
        return None
    try:
        tail = raw[raw.rindex(')') + 2:].split()
        return {'pid': int(pid), 'start': tail[19], 'ppid': int(tail[1]), 'name': raw[raw.index('(') + 1:raw.rindex(')')][:64]}
    except (ValueError, IndexError):
        return None


def talkers(raw=None, listening=None):
    """Processes ranked by open sockets, with their remote endpoints. Bandwidth per process needs privilege; counts do not."""
    raw = raw if raw is not None else run(['ss', '-tunpH'], 5)
    listening = listening if listening is not None else run(['ss', '-tulnH'], 5)
    groups, anonymous, total = {}, 0, 0
    for line in raw.splitlines():
        f = line.split()
        if len(f) < 6:
            continue
        proto, state, peer = f[0], f[1], f[5]
        if proto.startswith('tcp') and state != 'ESTAB':
            continue
        if peer.startswith('*') or peer.endswith(':*'):
            continue
        total += 1
        owners = re.findall(r'\("([^"]*)",pid=(\d+),fd=\d+\)', line)
        if not owners:
            anonymous += 1
            continue
        seen_pids = set()
        for name, pid in owners:
            if pid in seen_pids:
                continue
            seen_pids.add(pid)
            g = groups.setdefault(int(pid), {'pid': int(pid), 'name': name[:64], 'count': 0, 'tcp': 0, 'udp': 0, 'remotes': {}})
            g['count'] += 1
            g['tcp' if proto.startswith('tcp') else 'udp'] += 1
            host = peer_host(peer)
            g['remotes'][host] = g['remotes'].get(host, 0) + 1
    rows = sorted(groups.values(), key=lambda g: (-g['count'], g['name']))[:24]
    procs = None
    wins = None
    for g in rows:
        remotes = sorted(g['remotes'].items(), key=lambda kv: -kv[1])
        g['remotes'] = [{'host': h, 'count': c, 'kind': host_kind(h)} for h, c in remotes[:4]]
        g['hosts'] = len(remotes)
        p = process(g['pid'])
        g['start'] = p['start'] if p else ''
        try:
            g['owned'] = Path(f"/proc/{g['pid']}").stat().st_uid == os.getuid()
        except OSError:
            g['owned'] = False
        if g['owned'] and p:
            if procs is None:
                procs = all_processes()
                wins = clients()
            g['target'] = target_for(p, procs, wins)
        else:
            g['target'] = {}
    return {'rows': rows, 'total': total, 'anonymous': anonymous, 'listening': len([l for l in listening.splitlines() if l.strip()])}


def tcp_stats(snmp=None, sockstat=None, sockstat6=None):
    snmp = snmp if snmp is not None else read('/proc/net/snmp')
    sockstat = sockstat if sockstat is not None else read('/proc/net/sockstat')
    sockstat6 = sockstat6 if sockstat6 is not None else read('/proc/net/sockstat6')
    out = {}
    lines = snmp.splitlines()
    for i in range(len(lines) - 1):
        if lines[i].startswith('Tcp:') and lines[i + 1].startswith('Tcp:'):
            keys, values = lines[i].split()[1:], lines[i + 1].split()[1:]
            for k, v in zip(keys, values):
                if k in ('ActiveOpens', 'PassiveOpens', 'AttemptFails', 'EstabResets', 'CurrEstab', 'InSegs', 'OutSegs', 'RetransSegs', 'InErrs', 'OutRsts'):
                    out[k] = int(v)
    for line in sockstat.splitlines():
        head, _, rest = line.partition(':')
        v = rest.split()
        if head in ('TCP', 'UDP'):
            for k, val in zip(v[0::2], v[1::2]):
                out[head.lower() + k.capitalize()] = int(val)
    # Only the in-use counts are per-family; allocation and memory are shared,
    # so adding those would double-count them.
    for line in sockstat6.splitlines():
        head, _, rest = line.partition(':')
        v = rest.split()
        if head in ('TCP6', 'UDP6'):
            pairs = dict(zip(v[0::2], v[1::2]))
            if 'inuse' in pairs:
                key = head[:-1].lower() + 'Inuse'
                out[key] = out.get(key, 0) + int(pairs['inuse'])
    return out


# ----------------------------------------------------------------- pings

def ping_start(host):
    if not host or not re.fullmatch(r'[0-9a-fA-F:.]{3,45}', host):
        return None
    try:
        return subprocess.Popen(['ping', '-n', '-c', '1', '-W', '1', host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return None


def ping_collect(proc):
    """Return (done, milliseconds or -1 for timeout)."""
    if proc is None:
        return True, None
    if proc.poll() is None:
        return False, None
    out = proc.stdout.read() if proc.stdout else ''
    m = re.search(r'time[=<]([\d.]+)', out)
    return True, float(m.group(1)) if m and proc.returncode == 0 else -1


def summarize(samples):
    good = [s for s in samples if s is not None and s >= 0]
    lost = len([s for s in samples if s is not None and s < 0])
    return {'avg': sum(good) / len(good) if good else (-1 if lost else None), 'loss': 100 * lost / len(samples) if samples else 0, 'samples': samples[-PING_WINDOW:]}


# ----------------------------------------------------------------- window focus (shared with the sibling plugins)

def clients():
    try:
        value = json.loads(run(['hyprctl', 'clients', '-j']))
        return [c for c in value if isinstance(c, dict) and isinstance(c.get('pid'), int) and re.fullmatch(r'0x[0-9a-fA-F]+', str(c.get('address', '')))]
    except (ValueError, TypeError):
        return []


def environment(pid):
    # Only these routing identities ever leave this function. No credentials,
    # command lines, or full process environments are persisted.
    return {k: v for s in read(f'/proc/{pid}/environ').split('\0') for k, sep, v in [s.partition('=')] if sep and k in ENV_KEYS}


def all_processes():
    return {int(f.name): q for f in Path('/proc').iterdir() if f.name.isdigit() for q in [process(f.name)] if q}


def window_for(pid, procs, windows):
    seen = set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        if pid in windows:
            return windows[pid]
        pid = procs.get(pid, {}).get('ppid', 0)
    return None


def target_for(p, procs, wins):
    windows = {c['pid']: c for c in wins}
    w = window_for(p['pid'], procs, windows)
    env = environment(p['pid'])
    host = {}
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
            cs = environment(q['pid']).get('HERDR_SOCKET_PATH') or str(Path.home() / '.config/herdr/herdr.sock')
            if cw and cs == sock:
                w = cw
                host = {'kind': 'herdr', 'socket': sock, 'workspace': env.get('HERDR_WORKSPACE_ID', ''), 'tab': env.get('HERDR_TAB_ID', ''), 'pane': env['HERDR_PANE_ID']}
                break
    if not shell and not host and env.get('TMUX') and re.fullmatch(r'%\d+', env.get('TMUX_PANE', '')):
        sock = env['TMUX'].rsplit(',', 2)[0]
        pane = env['TMUX_PANE']
        session = run(['tmux', '-S', sock, 'display-message', '-p', '-t', pane, '#{session_id}']).strip()
        for line in run(['tmux', '-S', sock, 'list-clients', '-F', '#{client_pid}\t#{session_id}\t#{client_name}']).splitlines():
            parts = line.split('\t')
            if len(parts) == 3 and parts[0].isdigit() and parts[1] == session:
                cw = window_for(int(parts[0]), procs, windows)
                if cw:
                    w = cw
                    host = {'kind': 'tmux', 'socket': sock, 'pane': pane, 'client': parts[2]}
                    break
    return {'address': w['address'], 'title': str(w.get('title', ''))[:100], 'workspace': str(w.get('workspace', {}).get('name', '')), 'host': host} if w else {}


def focus(pid, start):
    # Re-read identity and routing on click; an old snapshot cannot focus a
    # recycled PID or run a command supplied by a window title.
    p = process(pid)
    if not p or p['start'] != start or Path(f'/proc/{pid}').stat().st_uid != os.getuid():
        raise RuntimeError('Process exited or identity changed. Refresh the list.')
    target = target_for(p, all_processes(), clients())
    if not target:
        raise RuntimeError('No existing window or attached session for this process.')
    host = target.get('host', {})
    if host.get('kind') == 'herdr':
        for kind, pattern in [('workspace', r'w[\w-]{1,32}'), ('tab', r'w[\w-]{1,32}:t[\w-]{1,32}'), ('pane', r'w[\w-]{1,32}:p[\w-]{1,32}')]:
            value = host.get(kind, '')
            if not re.fullmatch(pattern, value, re.ASCII):
                continue
            request = {'id': 'net-pulse:' + kind, 'method': kind + '.focus', 'params': {kind + '_id': value}}
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(2)
                s.connect(host['socket'])
                s.sendall((json.dumps(request) + '\n').encode())
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
            if subprocess.run(prefix + cmd, capture_output=True, timeout=2).returncode:
                raise RuntimeError('tmux could not focus this pane.')
    try:
        v = json.loads(run(['hyprctl', 'version', '-j']))
        match = re.search(r'(\d+)\.(\d+)', v.get('tag', v.get('version', '')))
        lua = bool(match and (int(match[1]), int(match[2])) >= (0, 56))
    except (ValueError, TypeError):
        lua = False
    addr = target['address']
    response = run(['hyprctl', 'dispatch'] + ([f'hl.dsp.focus({{ window = "address:{addr}" }})'] if lua else ['focuswindow', 'address:' + addr]))
    if not response or 'error' in response.lower():
        raise RuntimeError('Window focus failed; the window may have closed.')
    return {'message': 'Focused ' + p['name']}


# ----------------------------------------------------------------- history

def db_open():
    db = sqlite3.connect(STATE / 'history.sqlite3', timeout=5)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, rx REAL, tx REAL, latency REAL, signal REAL, iface TEXT, boot TEXT, span REAL)')
    # Databases written before spans were recorded gain the column; their rows
    # keep a NULL span and fall back to the nominal interval.
    if 'span' not in {row[1] for row in db.execute('PRAGMA table_info(samples)')}:
        db.execute('ALTER TABLE samples ADD COLUMN span REAL')
    # Bytes moved per hour per interface. Samples are pruned after a week, so
    # months and years of usage can only come from a rollup that outlives them;
    # at one row per hour per interface a decade is a few hundred kilobytes.
    fresh = db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='usage'").fetchone()[0] == 0
    db.execute('CREATE TABLE IF NOT EXISTS usage (hour INTEGER, iface TEXT, rx REAL, tx REAL, secs REAL, PRIMARY KEY (hour, iface))')
    if fresh:
        # An existing week of samples is worth carrying over rather than
        # starting the usage tab at zero on the release that adds it.
        db.execute('INSERT INTO usage (hour, iface, rx, tx, secs) '
                   'SELECT CAST(ts/3600 AS INTEGER)*3600, iface, SUM(rx*COALESCE(span,?)), SUM(tx*COALESCE(span,?)), SUM(COALESCE(span,?)) '
                   'FROM samples GROUP BY 1, 2', (HISTORY_INTERVAL, HISTORY_INTERVAL, HISTORY_INTERVAL))
        db.commit()
    return db


def record(db, ts, rx, tx, latency, signal, iface, span=HISTORY_INTERVAL):
    newest = db.execute('SELECT MAX(ts) FROM samples').fetchone()[0]
    db.execute('INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?)',
               (ts, rx, tx, latency, signal, iface, read('/proc/sys/kernel/random/boot_id').strip(), span))
    # Retention is destructive and irreversible, so it only runs when the new
    # timestamp is continuous with what is already stored. A clock corrected
    # forward by a week would otherwise erase the week it skipped over.
    db.execute('INSERT INTO usage (hour, iface, rx, tx, secs) VALUES (?,?,?,?,?) ON CONFLICT (hour, iface) '
               'DO UPDATE SET rx=rx+excluded.rx, tx=tx+excluded.tx, secs=secs+excluded.secs',
               (int(ts // 3600) * 3600, iface, rx * span, tx * span, span))
    if newest is None or ts - newest < 86400:
        db.execute('DELETE FROM samples WHERE ts < ?', (ts - SAMPLE_RETENTION,))
        db.execute('DELETE FROM usage WHERE hour < ?', (ts - USAGE_RETENTION,))
    db.commit()


def history(db, seconds, now=None):
    now = now or time.time()
    bucket = max(HISTORY_INTERVAL, seconds / 240)
    # Boot is part of each bucket; never connect a line across a reboot.
    rows = db.execute('SELECT MIN(ts), AVG(rx), MAX(rx), AVG(tx), AVG(latency), AVG(signal), COUNT(*), boot FROM samples WHERE ts>=? AND ts<=? GROUP BY CAST(ts/? AS INTEGER), boot ORDER BY MIN(ts)', (now - seconds, now, bucket)).fetchall()
    # Bytes are the rate over the time each sample actually covered, summed at
    # full resolution so bucketing cannot change the answer.
    totals = db.execute('SELECT SUM(rx*COALESCE(span,?)), SUM(tx*COALESCE(span,?)) FROM samples WHERE ts>=? AND ts<=?',
                        (HISTORY_INTERVAL, HISTORY_INTERVAL, now - seconds, now)).fetchone()
    return {'seconds': seconds, 'bucket': bucket, 'now': now, 'points': rows, 'count': sum(r[6] for r in rows),
            'peakRx': max((r[2] for r in rows), default=0), 'peakTx': max((r[3] or 0 for r in rows), default=0),
            'peakLatency': max((r[4] or 0 for r in rows), default=0),
            'totalRx': totals[0] or 0, 'totalTx': totals[1] or 0}


def usage_bucket(seconds):
    """Bar width for a window: enough bars to read, on boundaries you can name."""
    for limit, width in ((3600, 60), (86400, 3600), (604800, 21600), (2592000, 86400), (31536000, 604800)):
        if seconds <= limit:
            return width
    for width in USAGE_LADDER:
        if seconds / width <= 60:
            return width
    return USAGE_LADDER[-1]


def usage(db, seconds, now=None):
    """Bytes moved in a rolling window, bucketed for a bar chart.

    The last hour is read from the 15-second samples; every longer window comes
    from the hourly rollup, which is the only thing that outlives the one-week
    sample retention. Buckets align to the local clock, so a day starts at
    midnight here rather than at midnight UTC. `seconds` of 0 means everything
    ever recorded.
    """
    now = now or time.time()
    off = time.localtime(now).tm_gmtoff or 0
    first = db.execute('SELECT MIN(hour) FROM usage').fetchone()[0]
    window = float(seconds) if seconds else max(3600.0, now - first) if first is not None else 3600.0
    bucket = usage_bucket(window)
    start = now - window
    if seconds and seconds <= 3600:
        args = (HISTORY_INTERVAL, HISTORY_INTERVAL, HISTORY_INTERVAL, start, now)
        rows = db.execute('SELECT CAST((ts+?)/? AS INTEGER), SUM(rx*COALESCE(span,?)), SUM(tx*COALESCE(span,?)), SUM(COALESCE(span,?)) '
                          'FROM samples WHERE ts>=? AND ts<=? GROUP BY 1 ORDER BY 1', (off, bucket) + args).fetchall()
        ifaces = db.execute('SELECT iface, SUM(rx*COALESCE(span,?)), SUM(tx*COALESCE(span,?)) FROM samples '
                            'WHERE ts>=? AND ts<=? GROUP BY iface', (HISTORY_INTERVAL, HISTORY_INTERVAL, start, now)).fetchall()
        # One sample row per instant, so its spans already are wall-clock time.
        recorded = sum(r[3] or 0.0 for r in rows)
    else:
        # Whole hours only, so a window that begins mid-hour still shows the
        # bucket it lands in rather than silently dropping it.
        floor = int(start // 3600) * 3600
        rows = db.execute('SELECT CAST((hour+?)/? AS INTEGER), SUM(rx), SUM(tx), SUM(secs) FROM usage '
                          'WHERE hour>=? AND hour<=? GROUP BY 1 ORDER BY 1', (off, bucket, floor, now)).fetchall()
        ifaces = db.execute('SELECT iface, SUM(rx), SUM(tx) FROM usage WHERE hour>=? AND hour<=? GROUP BY iface',
                            (floor, now)).fetchall()
        # Two interfaces busy in the same hour are one hour of recording, not
        # two; summing their spans would claim more coverage than time passed.
        recorded = db.execute('SELECT SUM(s) FROM (SELECT MAX(secs) AS s FROM usage WHERE hour>=? AND hour<=? GROUP BY hour)',
                              (floor, now)).fetchone()[0] or 0.0
    points = [[b * bucket - off, r or 0.0, t or 0.0] for b, r, t, _ in rows]
    ifaces = sorted(([n or '—', r or 0.0, t or 0.0] for n, r, t in ifaces), key=lambda row: -(row[1] + row[2]))
    return {'seconds': window, 'requested': seconds, 'bucket': bucket, 'now': now,
            'start': int((start + off) // bucket) * bucket - off, 'points': points,
            'totalRx': sum(p[1] for p in points), 'totalTx': sum(p[2] for p in points),
            'peak': max((p[1] + p[2] for p in points), default=0.0),
            # How much of the window was actually being recorded. Without this a
            # fresh install reads "1.2 GB this year" as though the year were covered.
            # Edge buckets are counted whole, so coverage is capped at the window.
            'recorded': min(window, recorded), 'first': first,
            'ifaces': ifaces[:6]}


def atomic(name, value):
    path = STATE / name
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, separators=(',', ':'), ensure_ascii=True))
    tmp.replace(path)


# ----------------------------------------------------------------- daemon

def daemon():
    with (STATE / 'collector.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        db = db_open()
        cache = {'devices': {}, 'general': {}, 'addresses': {}, 'connections': {}, 'networks': [], 'band': {}, 'dns': [], 'provider': '', 'routes': [], 'saved': [],
                 'talkers': {'rows': [], 'total': 0, 'anonymous': 0, 'listening': 0}}
        jobs = {'medium': (6, medium_jobs), 'slow': (15, slow_jobs), 'talkers': (9, lambda c: c.update(talkers=talkers()))}
        due = {k: 0 for k in jobs}
        counters, counted_at, tcp_prev, tcp_at = None, 0, None, 0
        pings = {'gateway': None, 'internet': None}
        samples = {'gateway': [], 'internet': []}
        acc = {'rx': [], 'tx': [], 'latency': [], 'signal': []}
        last_history = time.monotonic()
        while True:
            start = time.monotonic()
            try:
                # Sample the counters first and timestamp that moment. Reading
                # them after the slow jobs charged their duration to the wrong
                # interval and made rates leap and collapse.
                sampled = time.monotonic()
                now_counters = netdev()
                tcp_now = tcp_stats()
                speed = rates(counters, now_counters, sampled - counted_at if counters else 0)
                counters, counted_at = now_counters, sampled
                tcp_rates = {k: max(0, tcp_now.get(k, 0) - tcp_prev.get(k, 0)) / (sampled - tcp_at) for k in ('RetransSegs', 'ActiveOpens', 'PassiveOpens', 'InSegs', 'OutSegs')} if tcp_prev and sampled > tcp_at else {}
                tcp_prev, tcp_at = tcp_now, sampled
                for name, (interval, fn) in jobs.items():
                    if start >= due[name]:
                        try:
                            fn(cache)
                        except (OSError, ValueError) as e:
                            print(f'Net Pulse: {name}: {type(e).__name__}: {e}', flush=True)
                        due[name] = start + interval
                route = default_route()
                iface = route.get('iface', '')
                for key, host in (('gateway', route.get('gateway', '')), ('internet', route.get('probe', PROBE) if iface else '')):
                    done, value = ping_collect(pings[key])
                    if done:
                        if pings[key] is not None:
                            samples[key] = (samples[key] + [value])[-PING_WINDOW:]
                        pings[key] = ping_start(host) if host else None
                        if not host:
                            samples[key] = []
                m = snapshot(cache, counters, speed, route, samples, tcp_now, tcp_rates)
                if iface:
                    acc['rx'].append(m['rates']['rx'])
                    acc['tx'].append(m['rates']['tx'])
                    if m['ping']['internet'] is not None:
                        acc['latency'].append(m['ping']['internet'] if m['ping']['internet'] >= 0 else None)
                    if m['wifi'].get('quality') is not None:
                        acc['signal'].append(m['wifi']['quality'])
                if start - last_history >= HISTORY_INTERVAL:
                    span = min(4 * HISTORY_INTERVAL, max(1.0, start - last_history))
                    if iface and acc['rx']:
                        lat = [v for v in acc['latency'] if v is not None]
                        record(db, m['ts'], sum(acc['rx']) / len(acc['rx']), sum(acc['tx']) / len(acc['tx']), sum(lat) / len(lat) if lat else None,
                               sum(acc['signal']) / len(acc['signal']) if acc['signal'] else None, iface, span)
                    atomic('history.json', {str(s): history(db, s, m['ts']) for s in (3600, 86400, 604800)})
                    atomic('usage.json', {str(s): usage(db, s, m['ts']) for s in USAGE_RANGES})
                    acc = {'rx': [], 'tx': [], 'latency': [], 'signal': []}
                    last_history = start
                atomic('snapshot.json', m)
            except (OSError, sqlite3.Error, RuntimeError, ValueError) as e:
                print(f'Net Pulse: {type(e).__name__}: {e}', flush=True)
            time.sleep(max(0.2, 2 - (time.monotonic() - start)))


def medium_jobs(cache):
    cache['devices'] = nm_devices()
    cache['general'] = nm_general()
    cache['addresses'] = addresses()
    cache['networks'] = wifi_list() if cache['general'].get('wifi') else []
    cache['band'] = band_status()
    wanted = {d['uuid'] for d in cache['devices'].values() if d.get('uuid')}
    cache['connections'] = {u: nm_connection(u) for u in wanted}
    cache['saved'] = nm_saved()


def slow_jobs(cache):
    cache['dns'] = resolve_status()
    cache['provider'] = dns_provider()
    cache['routes'] = routes()


def snapshot(cache, counters, speed, route, samples, tcp, tcp_rates):
    ts = time.time()
    iface = route.get('iface', '')
    devices, addrs = cache['devices'], cache['addresses']
    interfaces = []
    for name in sorted(counters):
        if name == 'lo':
            continue
        kind = iface_kind(name)
        dev = devices.get(name, {})
        a = addrs.get(name, {})
        entry = {'name': name, 'kind': kind, 'active': name == iface, 'mac': a.get('mac', ''), 'mtu': a.get('mtu', 0), 'operstate': a.get('operstate', ''), 'up': a.get('up', False),
                 'addrs4': a.get('addrs4', []), 'addrs6': a.get('addrs6', []), 'rates': speed.get(name, {'rx': 0, 'tx': 0}), 'stats': counters[name],
                 'nm': {'type': dev.get('type', ''), 'state': dev.get('state', ''), 'connection': dev.get('connection', ''), 'uuid': dev.get('uuid', '')},
                 'settings': cache['connections'].get(dev.get('uuid', ''), {}),
                 'profiles': profiles_for(cache.get('saved', []), name, kind)}
        entry.update(link_info(name))
        interfaces.append(entry)
    interfaces.sort(key=lambda e: (not e['active'], {'ethernet': 0, 'wifi': 1, 'tunnel': 2, 'bridge': 3}.get(e['kind'], 4), e['name']))
    active = next((e for e in interfaces if e['active']), {})
    wifi = wifi_link(iface) if iface and active.get('kind') == 'wifi' else {}
    if wifi:
        bssid = str(wifi.get('bssid', '')).lower()
        used = next((n for n in cache['networks'] if bssid and str(n.get('bssid', '')).lower() == bssid), None)
        if used is None:
            used = next((n for n in cache['networks'] if n['inUse']), None)
        if used:
            wifi['security'] = used['security']
            wifi['quality'] = used['signal']
        wifi['band'] = band_for(wifi.get('freq'))
    general = cache['general']
    gateway, internet = summarize(samples['gateway']), summarize(samples['internet'])
    return {'ts': ts, 'warm': True, 'online': bool(iface), 'connectivity': general.get('connectivity', 'unknown'), 'nmState': general.get('state', ''),
            'radio': {'wifi': general.get('wifi'), 'wifiHardware': general.get('wifiHardware')},
            'iface': {'name': iface, 'kind': active.get('kind', ''), 'gateway': route.get('gateway', ''), 'source': route.get('source', ''), 'mac': active.get('mac', ''), 'mtu': active.get('mtu', 0),
                      'speed': active.get('speed'), 'duplex': active.get('duplex', ''), 'driver': active.get('driver', ''), 'addrs4': active.get('addrs4', []), 'addrs6': active.get('addrs6', []),
                      'connection': active.get('nm', {}).get('connection', ''), 'uuid': active.get('nm', {}).get('uuid', ''), 'settings': active.get('settings', {})},
            'rates': active.get('rates', {'rx': 0, 'tx': 0}), 'totals': active.get('stats', {}),
            'wifi': wifi, 'band': cache['band'], 'networks': cache['networks'],
            'ping': {'gateway': gateway['avg'], 'internet': internet['avg'], 'loss': internet['loss'],
                     'probe': route.get('probe', PROBE), 'gatewaySamples': gateway['samples'], 'internetSamples': internet['samples']},
            'interfaces': interfaces, 'talkers': cache['talkers'], 'dns': {'provider': cache['provider'], 'links': cache['dns']}, 'routes': cache['routes'],
            'tcp': tcp, 'tcpRates': tcp_rates, 'forwarding': read('/proc/sys/net/ipv4/ip_forward').strip() == '1'}


# ----------------------------------------------------------------- actions

def latency_burst(hosts):
    procs = []
    for host in hosts:
        if host and re.fullmatch(r'[0-9a-fA-F:.]{3,45}', host):
            procs.append((host, subprocess.Popen(['ping', '-n', '-c', '10', '-i', '0.2', '-W', '1', host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)))
    results = {}
    for host, proc in procs:
        try:
            out, _ = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            out = ''
        rtt = re.search(r'= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms', out)
        loss = re.search(r'(\d+)% packet loss', out)
        results[host] = {'min': float(rtt.group(1)), 'avg': float(rtt.group(2)), 'max': float(rtt.group(3)), 'jitter': float(rtt.group(4))} if rtt else {}
        results[host]['loss'] = int(loss.group(1)) if loss else 100
    return results


def action_latency():
    route = default_route()
    if not route.get('iface'):
        raise RuntimeError('No default route; nothing to measure.')
    hosts = [h for h in (route.get('gateway', ''), route.get('probe', PROBE)) if h]
    r = latency_burst(hosts)
    parts = []
    for host in hosts:
        v = r.get(host, {})
        label = 'Gateway' if host == route.get('gateway') else 'Internet'
        parts.append(f"{label} {v['avg']:.1f} ms avg ({v['min']:.1f}–{v['max']:.1f}, jitter {v['jitter']:.1f}, loss {v['loss']}%)" if 'avg' in v else f"{label}: {v.get('loss', 100)}% loss")
    return {'message': '10-ping burst · ' + '  ·  '.join(parts), 'results': r}


def action_public_ip():
    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip'):
        value = run(['curl', '-fsS', '--max-time', '5', url], 8).strip()
        if re.fullmatch(r'[0-9a-fA-F:.]{3,45}', value):
            return {'message': 'Public address ' + value + ' (asked ' + url.split('/')[2] + ')', 'ip': value}
    raise RuntimeError('Public address lookup failed.')


def action_dns(provider):
    if provider not in PROVIDERS:
        raise RuntimeError('Unknown DNS provider.')
    p = subprocess.run(['omarchy-dns', provider], capture_output=True, text=True, timeout=45)
    if p.returncode:
        raise RuntimeError('DNS change was refused: ' + (p.stderr.strip() or p.stdout.strip() or 'no details')[:160])
    return {'message': 'DNS provider set to ' + provider + '.'}


def action_band(band):
    if band not in BANDS:
        raise RuntimeError('Unknown band.')
    p = subprocess.run(['omarchy-network-band', band], capture_output=True, text=True, timeout=45)
    if p.returncode:
        raise RuntimeError('Band change was refused: ' + (p.stderr.strip() or p.stdout.strip() or 'no details')[:160])
    return {'message': ('Band pinned to ' + band + ' GHz. Reconnecting…') if band != 'auto' else 'Band set to automatic. Reconnecting…'}


def action_connection(direction, uuid):
    if direction not in ('up', 'down') or not re.fullmatch(UUID_RE, uuid or ''):
        raise RuntimeError('Invalid connection request.')
    p = subprocess.run(['nmcli', 'con', direction, 'uuid', uuid], capture_output=True, text=True, timeout=45)
    if p.returncode:
        raise RuntimeError((p.stderr.strip() or p.stdout.strip() or 'NetworkManager refused')[:160])
    return {'message': 'Connection ' + ('activated.' if direction == 'up' else 'deactivated.')}


def action_autoconnect(uuid, value):
    if value not in ('yes', 'no') or not re.fullmatch(UUID_RE, uuid or ''):
        raise RuntimeError('Invalid autoconnect request.')
    p = subprocess.run(['nmcli', 'con', 'modify', 'uuid', uuid, 'connection.autoconnect', value], capture_output=True, text=True, timeout=20)
    if p.returncode:
        raise RuntimeError((p.stderr.strip() or 'NetworkManager refused')[:160])
    return {'message': 'Autoconnect ' + ('enabled.' if value == 'yes' else 'disabled.')}


def action_rescan():
    p = subprocess.run(['nmcli', 'dev', 'wifi', 'rescan'], capture_output=True, text=True, timeout=20)
    if p.returncode and 'too soon' not in p.stderr.lower():
        raise RuntimeError((p.stderr.strip() or 'Scan refused')[:160])
    return {'message': 'Scanning for nearby networks…'}


def action_flush_dns():
    p = subprocess.run(['resolvectl', 'flush-caches'], capture_output=True, text=True, timeout=10)
    if p.returncode:
        raise RuntimeError((p.stderr.strip() or 'systemd-resolved refused')[:160])
    return {'message': 'DNS cache flushed.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['daemon', 'snapshot', 'focus', 'latency', 'publicip', 'dns', 'band', 'connection', 'autoconnect', 'rescan', 'flushdns'])
    parser.add_argument('args', nargs='*')
    a = parser.parse_args()
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        if a.action == 'daemon':
            daemon()
            return
        arg = a.args + ['', '']
        value = {'snapshot': lambda: snapshot({'devices': nm_devices(), 'general': nm_general(), 'addresses': addresses(), 'connections': {}, 'networks': wifi_list(), 'band': band_status(), 'dns': resolve_status(), 'provider': dns_provider(), 'routes': routes(), 'talkers': talkers()}, netdev(), {}, default_route(), {'gateway': [], 'internet': []}, tcp_stats(), {}),
                 'focus': lambda: focus(int(arg[0]), arg[1]), 'latency': action_latency, 'publicip': action_public_ip, 'dns': lambda: action_dns(arg[0]),
                 'band': lambda: action_band(arg[0]), 'connection': lambda: action_connection(arg[0], arg[1]), 'autoconnect': lambda: action_autoconnect(arg[0], arg[1]),
                 'rescan': action_rescan, 'flushdns': action_flush_dns}[a.action]()
        print(json.dumps(value))
    except Exception as e:
        print(json.dumps({'error': str(e)}))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
