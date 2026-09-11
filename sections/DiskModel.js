.pragma library
function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, Number(v) || 0)) }
function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
function has(v) { return v !== null && v !== undefined && isFinite(Number(v)) }
// The headroom ramp is the one colour on screen that carries meaning rather
// than style, so it stays a traffic light — but in the active theme's own red,
// yellow and green. These constants are the ramp the plugin shipped with, and
// they stand in for any key a theme leaves out. They are the same three stops
// RAM Pulse, CPU Pulse and Net Pulse ship, which is what makes the four chips
// read as siblings beside each other on the bar.
var RAMP_FALLBACK = {low: '#850d29', mid: '#efcc45', high: '#43f2a1'}

function rgbOf(hex, fallback) {
    var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(String(hex || '').trim())
    if (!m) return fallback
    return [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)]
}

function hexOf(rgb) {
    var out = '#'
    for (var i = 0; i < 3; i++) {
        var v = Math.round(Math.min(Math.max(rgb[i], 0), 1) * 255).toString(16)
        out += v.length < 2 ? '0' + v : v
    }
    return out
}

function rgbToHsl(r, g, b) {
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, h = 0, s = 0
    if (mx !== mn) {
        var d = mx - mn
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        if (mx === r) h = (g - b) / d + (g < b ? 6 : 0)
        else if (mx === g) h = (b - r) / d + 2
        else h = (r - g) / d + 4
        h /= 6
    }
    return [h, s, l]
}

function hslToRgb(h, s, l) {
    if (s === 0) return [l, l, l]
    var hi = l < 0.5 ? l * (1 + s) : l + s - l * s
    var lo = 2 * l - hi
    function stop(t) {
        if (t < 0) t += 1
        if (t > 1) t -= 1
        if (t < 1/6) return lo + (hi - lo) * 6 * t
        if (t < 1/2) return hi
        if (t < 2/3) return lo + (hi - lo) * (2/3 - t) * 6
        return lo
    }
    return [stop(h + 1/3), stop(h), stop(h - 1/3)]
}

// Half the themes on a typical box define a red, yellow and green too muted to
// work as a warning: 2-haxorz's three stops sit at 0.23, 0.13 and 0.11
// saturation, and vantablack's are pure greyscale. The ramp keeps each theme's
// hue and raises only what it must to stay tellable apart at a glance. A stop
// with almost no chroma has no hue worth preserving, so the shipped hue stands
// in rather than tinting grey at random.
var RAMP_MIN_SAT = 0.55
var RAMP_MIN_LIGHT = 0.30
var RAMP_MAX_LIGHT = 0.78
var RAMP_HUE_FLOOR = 0.02

// Themes name their palette either directly or as terminal colour slots. The
// named key wins where a theme defines both, so it leads each list.
var PALETTE_ALIASES = {red: ['red', 'color1'], yellow: ['yellow', 'color3'],
                       green: ['green', 'color2']}

// How far apart the three stops must sit, as a weighted RGB distance, before
// the theme's own colours are used. Measured after lifting, never before.
var RAMP_SEPARATION_MIN = 80

// Weighted RGB distance ("redmean"), a cheap stand-in for a perceptual metric.
// Accurate enough to tell three distinct hues from three shades of one mud,
// which is the only judgement the ramp needs it to make.
function separation(a, b) {
    var mean = (a[0] + b[0]) / 2, dr = a[0] - b[0], dg = a[1] - b[1], db = a[2] - b[2]
    return Math.sqrt((2 + mean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - mean) / 256) * db * db)
}

function readableStop(themeHex, shippedHex) {
    var t = rgbOf(themeHex, null)
    if (!t) return shippedHex
    var shipped = rgbOf(shippedHex, [128, 128, 128])
    var a = rgbToHsl(t[0]/255, t[1]/255, t[2]/255)
    var b = rgbToHsl(shipped[0]/255, shipped[1]/255, shipped[2]/255)
    var hue = a[1] < RAMP_HUE_FLOOR ? b[0] : a[0]
    var sat = Math.max(a[1], RAMP_MIN_SAT)
    var light = Math.min(Math.max(a[2], RAMP_MIN_LIGHT), RAMP_MAX_LIGHT)
    return hexOf(hslToRgb(hue, sat, light))
}

// colors.toml is the theme's own palette file. Only the three keys the ramp
// needs are read; a theme that omits one keeps the shipped colour for that
// stop rather than falling back to a whole foreign ramp. The shipped colours
// are deliberate and are never put through the floor.
function themeRamp(text) {
    var found = {}, lines = String(text || '').split('\n')
    for (var i = 0; i < lines.length; i++) {
        var m = /^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/.exec(lines[i])
        if (m) found[m[1].toLowerCase()] = m[2]
    }
    var slots = {red: 'low', yellow: 'mid', green: 'high'}
    var out = {low: RAMP_FALLBACK.low, mid: RAMP_FALLBACK.mid, high: RAMP_FALLBACK.high}
    var complete = true
    for (var role in slots) {
        var slot = slots[role], keys = PALETTE_ALIASES[role], picked = null
        for (var k = 0; k < keys.length; k++) {
            if (found[keys[k]] && rgbOf(found[keys[k]], null)) { picked = found[keys[k]]; break }
        }
        if (picked === null) { complete = false; continue }
        out[slot] = readableStop(picked, RAMP_FALLBACK[slot])
    }
    // A partial palette is not a palette: mixing two theme stops with one
    // shipped one produces a ramp neither designed.
    if (!complete) return {low: RAMP_FALLBACK.low, mid: RAMP_FALLBACK.mid, high: RAMP_FALLBACK.high}
    // Three stops that are really one colour cannot be pulled apart by any
    // amount of saturation, so the shipped ramp stands in for the whole set.
    var low = rgbOf(out.low, null), mid = rgbOf(out.mid, null), high = rgbOf(out.high, null)
    if (separation(low, mid) < RAMP_SEPARATION_MIN || separation(mid, high) < RAMP_SEPARATION_MIN)
        return {low: RAMP_FALLBACK.low, mid: RAMP_FALLBACK.mid, high: RAMP_FALLBACK.high}
    return out
}

// Colour follows free space: the ramp's low stop with none left, its mid at
// half, its high with room to grow.
function ramp(percent, palette) {
    var p = palette || RAMP_FALLBACK
    var low = rgbOf(p.low, [133, 13, 41])
    var mid = rgbOf(p.mid, [239, 204, 69])
    var high = rgbOf(p.high, [67, 242, 161])
    var f = clamp(percent, 0, 100) / 100
    var a = f <= 0.5 ? low : mid
    var b = f <= 0.5 ? mid : high
    var t = f <= 0.5 ? f * 2 : (f - 0.5) * 2
    return Qt.rgba((a[0]+(b[0]-a[0])*t)/255, (a[1]+(b[1]-a[1])*t)/255, (a[2]+(b[2]-a[2])*t)/255, 1)
}

// Capacity is counted in binary units, the way df -h and the filesystem
// itself count, so the numbers here agree with the ones in a terminal.
function gib(v) { return (num(v)/1073741824).toFixed(1) }
function size(v) {
    var n = Math.max(0, num(v))
    if (n >= 1099511627776) return (n/1099511627776).toFixed(2)+' TiB'
    if (n >= 1073741824) return gib(n)+' GiB'
    if (n >= 1048576) return (n/1048576).toFixed(1)+' MiB'
    return (n/1024).toFixed(0)+' KiB'
}
// The hero number and its unit, split so the unit can sit small beside it.
function heroAmount(v) {
    var n = Math.max(0, num(v))
    if (n >= 1099511627776) return {value: (n/1099511627776).toFixed(2), unit: 'TiB'}
    return {value: gib(n), unit: 'GiB'}
}
// Throughput and drive lifetime totals are decimal, the way drive makers and
// benchmarks quote them: 1 MB/s is 1,000,000 bytes per second.
function rate(bps) {
    var n = Math.max(0, num(bps))
    if (n >= 1e9) return (n/1e9).toFixed(2)+' GB/s'
    if (n >= 1e6) return (n/1e6).toFixed(1)+' MB/s'
    if (n >= 1e3) return (n/1e3).toFixed(1)+' KB/s'
    return n.toFixed(0)+' B/s'
}
function dec(bytes) {
    var n = Math.max(0, num(bytes))
    if (n >= 1e15) return (n/1e15).toFixed(2)+' PB'
    if (n >= 1e12) return (n/1e12).toFixed(2)+' TB'
    if (n >= 1e9) return (n/1e9).toFixed(1)+' GB'
    if (n >= 1e6) return (n/1e6).toFixed(1)+' MB'
    if (n >= 1e3) return (n/1e3).toFixed(1)+' KB'
    return n.toFixed(0)+' B'
}
// Compact rates for a graph axis, where a full unit will not fit.
function shortRate(bps) {
    var n = Math.max(0, num(bps))
    if (n >= 1e9) return (n/1e9).toFixed(1)+'G'
    if (n >= 1e6) return (n/1e6).toFixed(n >= 1e7 ? 0 : 1)+'M'
    if (n >= 1e3) return (n/1e3).toFixed(0)+'K'
    return n.toFixed(0)+'B'
}
// Bar throughput. Three significant figures and a one-letter unit hold every
// reading to five characters, which is what lets the bar reserve one width
// without reserving a lot of dead space beside it. The dashboard and the
// tooltip keep the full "254.2 KB/s" form; this is only for the strip.
function tight(bps) {
    var n = Math.max(0, num(bps))
    var units = [[1e9, 'G'], [1e6, 'M'], [1e3, 'K']]
    for (var i = 0; i < units.length; i++) {
        var v = n/units[i][0]
        // 0.9995 and not 1: 999.9 KB/s must roll up to 1.0M rather than
        // round to a sixth character as "1000K".
        if (v >= 0.9995) return (v >= 99.95 ? v.toFixed(0) : v.toFixed(1))+units[i][1]
    }
    return n.toFixed(0)+'B'
}
function pct(v) { return has(v) ? Number(v).toFixed(1)+'%' : '—' }
function whole(v) { return has(v) ? Math.round(Number(v))+'%' : '—' }
function temp(v) { return has(v) ? Math.round(Number(v))+'°C' : '—' }
function ms(v) { return has(v) ? (Number(v) < 10 ? Number(v).toFixed(1) : Number(v).toFixed(0))+' ms' : '—' }
function count(v) {
    var n = num(v)
    return n >= 1e6 ? (n/1e6).toFixed(1)+'M' : n >= 1e4 ? (n/1e3).toFixed(1)+'k' : n.toFixed(0)
}
function perSec(v) { return count(v)+'/s' }
// Power-on time from hours, the unit NVMe reports it in.
function hours(h) {
    if (!has(h)) return '—'
    var n = Math.max(0, num(h))
    if (n < 48) return n.toFixed(0)+' h'
    if (n < 24*365) return (n/24).toFixed(0)+' days'
    return (n/(24*365)).toFixed(1)+' years'
}
function ago(seconds) {
    var s = Math.max(0, Math.floor(num(seconds)))
    if (s < 60) return s+'s'
    if (s < 3600) return Math.floor(s/60)+'m '+(s%60)+'s'
    if (s < 86400) return Math.floor(s/3600)+'h '+Math.floor(s%3600/60)+'m'
    return Math.floor(s/86400)+'d '+Math.floor(s%86400/3600)+'h'
}
// The filesystem the chip follows: the inline setting names a mount point,
// and the root filesystem stands in when that mount is not present.
function primaryOf(m, mountpoint) {
    var list = m && m.filesystems ? m.filesystems : []
    var want = String(mountpoint || '/')
    for (var i = 0; i < list.length; i++) if (list[i].mount === want) return list[i]
    for (var j = 0; j < list.length; j++) if (list[j].mount === '/') return list[j]
    return list.length ? list[0] : null
}
// The drive behind the primary filesystem, or the busiest one when the
// filesystem cannot be traced to a physical device (a network share).
function driveOf(m, primary) {
    var list = m && m.disks ? m.disks : []
    if (primary && primary.device) {
        for (var i = 0; i < list.length; i++) if (list[i].name === primary.device) return list[i]
    }
    var best = null
    for (var j = 0; j < list.length; j++) if (!best || num(list[j].rates && list[j].rates.util) > num(best.rates && best.rates.util)) best = list[j]
    return best
}
function readout(m, mode, mountpoint) {
    if (!m || !m.warm) return '—'
    var p = primaryOf(m, mountpoint)
    if (mode === 4) return 'R '+tight(m.rates ? m.rates.read : 0)
    if (mode === 5) { var d = driveOf(m, p); return temp(d ? d.temp : null) }
    if (!p || !has(p.freePct)) return '—'
    if (mode === 1) return pct(p.usedPct)
    if (mode === 2) return size(p.free)
    if (mode === 3) return size(p.used)
    return pct(p.freePct)
}
function modeTag(m, mode) {
    if (mode === 1 || mode === 3) return 'USED'
    if (mode === 4) return 'W '+tight(m && m.rates ? m.rates.write : 0)
    if (mode === 5) return 'DRIVE'
    return 'FREE'
}
// The bar widget must not change width as a reading changes. Every resize
// re-lays out the whole bar section it sits in, and on a full bar the sections
// briefly overlap before the shell settles -- the readout ends up drawn over
// the widget to its right. So each mode whose text changes every sample
// reserves the width of the widest string it can produce. These are floors,
// never limits: the live text still wins if it runs wider, so nothing clips.
// The two amount modes reserve nothing: capacity moves by a digit rarely.
function widestReadout(mode) {
    if (mode === 2 || mode === 3) return ''
    // 'M' is the widest unit letter and 99.9 the widest of the five-character
    // readings, so 'R 99.9M' dominates every rate tight() emits.
    if (mode === 4) return 'R 99.9M'
    if (mode === 5) return '99°C'
    return '100.0%'
}
function widestTag(mode) {
    if (mode === 2 || mode === 3) return ''
    if (mode === 4) return 'W 99.9M'
    if (mode === 5) return 'DRIVE'
    return 'USED'
}
function modeName(mode) { return ['% free', '% used', 'Amount free', 'Amount used', 'Read / write', 'Drive temperature'][mode] || '% free' }
// One line for the status pill. Fullness and stalling outrank a warm drive,
// because they are the two things that stop work; a drive at its warning
// temperature is still doing its job.
function healthLabel(m, primary, drive, stale) {
    if (stale || !m || !m.warm) return 'WAITING FOR TELEMETRY'
    // A share that is not answering, or a filesystem whose capacity has not
    // been read, is unknown. Unknown is not full: null must never become 0%.
    if (primary && (primary.responsive === false || !has(primary.freePct))) return 'CAPACITY UNKNOWN'
    var psi = m.psi && m.psi.some ? num(m.psi.some.avg10) : 0
    var free = primary ? num(primary.freePct) : 100
    var util = drive && drive.rates ? num(drive.rates.util) : 0
    if (free < 5) return 'DISK IS NEARLY FULL'
    if (psi >= 10) return 'STORAGE IS STALLING'
    if (drive && has(drive.temp) && has(drive.tempMax) && num(drive.temp) >= num(drive.tempMax)) return 'DRIVE IS RUNNING HOT'
    if (util >= 85) return 'DRIVE IS SATURATED'
    if (free < 15) return 'LOW HEADROOM'
    return 'ROOM TO GROW'
}
// Axis ceiling for the history graph: 1–2–5 steps, never below 100 KB/s so
// a quiet drive is not magnified into noise.
function niceMax(v) {
    var n = Math.max(1e5, num(v)*1.15)
    var p = Math.pow(10, Math.floor(Math.log(n)/Math.LN10))
    var f = n/p
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10)*p
}
// XDG requires an absolute path; a relative one would resolve against
// whichever working directory the recorder and the panel each happen to have.
function stateDir(home, xdg) { return (xdg && xdg.charAt(0) === '/' ? xdg : home+'/.local/state')+'/disk-pulse' }
