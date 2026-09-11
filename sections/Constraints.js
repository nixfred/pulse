.pragma library

// What is actually holding this machine back, per domain.
//
// Every entry is {key, label, value, detail, severity}. `severity` is 0..1 on
// one shared scale so the four domains can be ranked against each other: 0 is
// "not a constraint", 1 is "this is the thing stopping you". The thresholds
// below are the point where a reading starts costing you something you would
// notice, not the point where it becomes alarming — a disk at 85% full is a
// constraint on what you can do next even though nothing is broken.
//
// Nothing here reads the disk or the network. It is pure arithmetic over the
// snapshot each collector already wrote, so the Constraints page costs the
// same as looking at any other tab.

var LOW = 0.34        // worth knowing
var MEDIUM = 0.62     // worth acting on soon
var HIGH = 0.85       // acting on now
// A live reading can reach 0.97 but never 1. Only `offline` scores 1, so a
// stopped recorder always outranks a saturated one. Without this, a RAM stall
// average that pinned its ramp tied at 1.00 with a dead collector, and the
// tie-break — first domain wins — meant the dead one could never take the icon.
var CEILING = 0.97

function clamp01(n) {
    if (typeof n !== 'number' || !isFinite(n)) return 0
    return n < 0 ? 0 : n > 1 ? 1 : n
}

// Linear severity: `at` scores 0, `full` scores 1, in whichever direction.
function ramp(value, at, full) {
    if (typeof value !== 'number' || !isFinite(value)) return 0
    return clamp01((value - at) / (full - at))
}

function pct(n) {
    return typeof n === 'number' && isFinite(n) ? n.toFixed(n >= 10 ? 0 : 1) + '%' : '—'
}
function ms(n) {
    return typeof n === 'number' && isFinite(n) && n >= 0 ? (n < 10 ? n.toFixed(1) : Math.round(n)) + ' ms' : '—'
}
function deg(n) {
    return typeof n === 'number' && isFinite(n) ? Math.round(n) + '°C' : '—'
}
function size(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes) || bytes < 0) return '—'
    var units = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, n = bytes
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + units[i]
}

function band(severity) {
    return severity >= HIGH ? 'critical' : severity >= MEDIUM ? 'tight' : severity >= LOW ? 'noticeable' : 'comfortable'
}

function entry(key, label, value, detail, severity) {
    var s = Math.min(clamp01(severity), CEILING)
    return {key: key, label: label, value: value, detail: detail,
            severity: s, band: band(s)}
}

function offline(domain, unit) {
    // Built directly rather than through entry(), because this is the one
    // reading allowed to score a full 1.
    return [{key: 'offline', label: 'Recorder offline', value: 'no telemetry',
             detail: 'Nothing has been recorded for this domain recently. Check ' + unit + '.',
             severity: 1, band: 'critical'}]
}

// The mean of a ping series is dominated by a single stall. 23 samples between
// 0.4 and 2.3 ms plus one 565 ms outlier averages to 24 ms, which reads as a
// problem on a link that is fine. The median describes the typical packet.
function median(values, fallback) {
    if (!values || !values.length) return fallback
    var sorted = [], i
    for (i = 0; i < values.length; i++) {
        var n = Number(values[i])
        if (isFinite(n)) sorted.push(n)
    }
    if (!sorted.length) return fallback
    sorted.sort(function (a, b) { return a - b })
    var mid = Math.floor(sorted.length / 2)
    return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

function rank(list) {
    return list.slice().sort(function (a, b) { return b.severity - a.severity })
}

function worstOf(list) {
    var top = null
    for (var i = 0; i < list.length; i++) if (!top || list[i].severity > top.severity) top = list[i]
    return top
}

// ---- CPU ----------------------------------------------------------------
function cpu(c, stale) {
    if (stale || !c || !c.ts) return offline('CPU', 'cpu-pulse.service')
    var out = []
    var psi = c.psi || {}, some = psi.some || {}, full = psi.full || {}
    var cores = c.cores || [], threads = c.threads || cores.length || 1

    out.push(entry('load', 'Sustained load', pct(c.busyPct),
        'How much of the processor is already committed. Above about half, new work starts waiting behind existing work.',
        ramp(c.busyPct, 50, 100)))

    var saturated = 0
    for (var i = 0; i < cores.length; i++) if ((cores[i].busy || 0) >= 85) saturated++
    out.push(entry('threads', 'Saturated threads', saturated + ' of ' + threads,
        saturated === 0 ? 'No thread is pinned. Single-threaded work still has somewhere to run.'
                        : saturated + ' of ' + threads + ' threads are effectively full, so anything single-threaded is now competing for what is left.',
        threads ? saturated / threads : 0))

    out.push(entry('thermal', 'Package temperature', deg(c.temp),
        'Sustained heat is what makes a laptop clock down. Above 90°C the processor is trading speed for survival.',
        ramp(c.temp, 80, 95)))

    out.push(entry('pressure', 'Scheduler pressure', pct(some.avg60),
        'The share of the last minute that something spent waiting for a core rather than running. This is contention you can feel.',
        ramp(some.avg60, 0, 25)))

    if (c.profile === 'power-saver') {
        out.push(entry('profile', 'Power profile', 'power-saver',
            'The machine is deliberately capped. This is a constraint you chose, and switching to balanced lifts it.', 0.4))
    }
    // throttle is {package, core} counters, not a flag. Testing the object
    // itself is always true, which reported a permanent clock cap on a machine
    // that had never throttled.
    var thr = c.throttle || {}
    var thrCount = (Number(thr.package) || 0) + (Number(thr.core) || 0)
    if (thrCount > 0) {
        out.push(entry('throttle', 'Throttling events', String(thrCount),
            'The kernel has counted an active clock cap. Heat or power delivery is limiting the processor.',
            ramp(thrCount, 0, 8)))
    }
    return rank(out)
}

// ---- RAM ----------------------------------------------------------------
function ram(m, stale) {
    if (stale || !m || !m.ts) return offline('RAM', 'ram-pulse.service')
    var out = []
    var psi = m.psi || {}, some = psi.some || {}, full = psi.full || {}

    out.push(entry('headroom', 'Free headroom', pct(m.availablePct),
        'What is left for the next thing you open, cache included. Under about a fifth, the kernel starts reclaiming instead of allocating.',
        ramp(m.availablePct, 25, 0)))

    // swapTotal counts zram alongside the swapfile, and zram is compressed RAM
    // rather than disk. Measuring the two together called a healthy machine
    // half-swapped. Only the disk-backed devices are a real cost here.
    var diskTotal = 0, diskUsed = 0
    var devices = m.swaps || []
    for (var s = 0; s < devices.length; s++) {
        var name = String(devices[s].name || '')
        if (name.indexOf('zram') >= 0) continue
        diskTotal += Number(devices[s].total) || 0
        diskUsed += Number(devices[s].used) || 0
    }
    var swapRatio = diskTotal ? diskUsed / diskTotal : 0
    out.push(entry('swap', 'Swapped to disk', diskTotal ? size(diskUsed) + ' of ' + size(diskTotal) : 'no disk swap',
        !diskTotal ? 'There is no swapfile, so memory pressure has nowhere to go but reclaim and the OOM killer.'
                   : swapRatio > 0.05 ? 'Pages have been written out to storage. Touching them again costs a disk read instead of a memory read.'
                                      : 'Nothing meaningful has been written out to storage.',
        diskTotal ? ramp(swapRatio, 0.05, 0.6) : 0.3))

    out.push(entry('pressure', 'Memory pressure', pct(some.avg60),
        'The share of the last minute spent waiting on memory reclaim. This is the number that turns into stutter.',
        ramp(some.avg60, 0, 20)))

    out.push(entry('stall', 'Full stalls', pct(full.avg60),
        'Time where every task was blocked on memory at once. Anything sustained here is the machine grinding.',
        ramp(full.avg60, 0, 20)))

    // zram reports {original, physical}: the logical bytes stored and the RAM
    // they actually occupy after compression. There is no total/used pair.
    var z = m.zram || {}
    var held = Number(z.physical) || 0
    if (held > 0 && m.total) {
        var ratio = z.original && held ? z.original / held : 0
        out.push(entry('zram', 'Held in compressed swap', size(held) + ' of RAM'
                       + (ratio > 1 ? ' holding ' + size(z.original) + ' (' + ratio.toFixed(1) + 'x)' : ''),
            'zram absorbs pressure in RAM rather than on disk. It buys headroom, at the cost of CPU to compress and of the RAM it occupies.',
            ramp(held / m.total, 0.15, 0.5)))
    }
    return rank(out)
}

// ---- Disk ---------------------------------------------------------------
function disk(d, mountpoint, primary, drive, stale) {
    if (stale || !d || !d.ts) return offline('Disk', 'disk-pulse.service')
    var out = []
    var psi = d.psi || {}, some = psi.some || {}, full = psi.full || {}

    if (primary) {
        out.push(entry('space', 'Free space on ' + (primary.mount || mountpoint), pct(primary.freePct),
            size(primary.free) + ' left of ' + size(primary.total) + '. Under a fifth free, allocation slows and a filesystem like btrfs starts working harder to find room.',
            ramp(primary.freePct, 20, 0)))
    }

    // The bar follows one filesystem, but a full /boot stops an update whether
    // or not you happen to be watching it. Score the tightest of the others
    // too. Remote mounts are skipped: a full rclone target is not this
    // machine's constraint and its free space can be nonsense.
    var tightest = null
    var mounts = d.filesystems || []
    for (var f = 0; f < mounts.length; f++) {
        var fs = mounts[f]
        if (!fs || fs.remote) continue
        if (primary && fs.mount === primary.mount) continue
        if (typeof fs.freePct !== 'number') continue
        if (!tightest || fs.freePct < tightest.freePct) tightest = fs
    }
    if (tightest) {
        out.push(entry('othermount', 'Free space on ' + tightest.mount, pct(tightest.freePct),
            size(tightest.free) + ' left of ' + size(tightest.total) + ' on ' + (tightest.fstype || 'this filesystem')
            + '. The bar follows ' + (primary ? primary.mount : mountpoint) + ', so this one fills without ever changing the chip.',
            ramp(tightest.freePct, 20, 0)))
    }

    var rates = drive && drive.rates ? drive.rates : {}
    out.push(entry('busy', 'Drive busy time', pct(rates.util),
        'The share of the last interval the drive spent servicing requests. Near full, every new read queues behind the ones already running.',
        ramp(rates.util, 60, 100)))

    out.push(entry('pressure', 'I/O pressure', pct(some.avg60),
        'The share of the last minute something spent waiting on storage. Unlike throughput, this is the part you actually feel.',
        ramp(some.avg60, 0, 20)))

    out.push(entry('stall', 'Full I/O stalls', pct(full.avg60),
        'Time where everything was blocked on storage at once.',
        ramp(full.avg60, 0, 5)))

    if (drive) {
        var smart = drive.smart || {}
        var warn = smart.warnTemp || 80
        out.push(entry('thermal', 'Drive temperature', deg(drive.temp),
            'An NVMe drive that reaches its warning temperature (' + deg(warn) + ') throttles writes to cool down.',
            ramp(drive.temp, warn - 20, warn)))

        if (smart.warnings && smart.warnings.length) {
            out.push(entry('smart', 'SMART warnings', String(smart.warnings.length),
                'The drive is reporting: ' + smart.warnings.join(', ') + '. This is the drive telling you it is failing.', 1))
        } else if (typeof smart.percentUsed === 'number') {
            out.push(entry('wear', 'Drive wear', smart.percentUsed + '% of rated life',
                'Endurance consumed, by the drive\'s own estimate' +
                (smart.powerOnHours ? ' after ' + smart.powerOnHours + ' hours powered on.' : '.'),
                ramp(smart.percentUsed, 50, 100)))
        }
    }
    return rank(out)
}

// ---- Network ------------------------------------------------------------
function net(n, stale) {
    if (stale || !n || !n.ts) return offline('Network', 'net-pulse.service')
    var out = []
    var ping = n.ping || {}, wifi = n.wifi || {}

    if (!n.online) {
        out.push(entry('offline', 'No route out', 'offline',
            'Nothing can reach the internet from here right now.', 1))
    } else if (String(n.connectivity || '') !== 'full') {
        out.push(entry('captive', 'Partial connectivity', String(n.connectivity || 'unknown'),
            'There is a route, but the usual checks are not coming back clean. A captive portal or a filtered DNS will look like this.', 0.8))
    }

    var internetTypical = median(ping.internetSamples, ping.internet)
    out.push(entry('latency', 'Internet round trip', ms(internetTypical),
        'How long the median packet takes to reach ' + (ping.probe || 'the probe target') + ' and return. Everything interactive is built on top of this number.',
        ramp(internetTypical, 40, 200)))

    out.push(entry('loss', 'Packet loss', pct(ping.loss),
        'Lost packets are re-sent, so loss costs far more than its percentage suggests.',
        ramp(ping.loss, 0, 10)))

    if (typeof wifi.quality === 'number') {
        out.push(entry('signal', 'Wi-Fi signal', wifi.quality + '%' + (wifi.band ? ' on ' + wifi.band : ''),
            'Signal quality sets the rate the radio can negotiate. Below about 40% the link starts trading speed for reliability.',
            ramp(wifi.quality, 60, 0)))
    }

    var gatewayTypical = median(ping.gatewaySamples, ping.gateway)
    out.push(entry('gateway', 'Gateway round trip', ms(gatewayTypical),
        'The first hop, as the median packet sees it. Latency here is your own network, not the internet, so it separates a slow link from a slow world.',
        ramp(gatewayTypical, 5, 60)))

    return rank(out)
}
