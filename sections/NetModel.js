.pragma library
function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, Number(v) || 0)) }
function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
function has(v) { return v !== null && v !== undefined && isFinite(Number(v)) }
// Colour follows link health: dark red offline, yellow when struggling, green when the path is clean.
// Mix two colours. Every surface, rule and dim label in the dashboard is the
// theme's own background lifted toward its own text by some fraction, which
// lands correctly on a light theme as well as a dark one -- unlike a fixed
// slate palette, and unlike Qt.lighter(), which barely moves a near-black.
function mix(a, b, t) {
    var f = clamp(t, 0, 1)
    return Qt.rgba(a.r + (b.r - a.r)*f, a.g + (b.g - a.g)*f, a.b + (b.b - a.b)*f, 1)
}
// Built-in link ramp: dark red offline, yellow when struggling, green when the
// path is clean. Used whenever the theme has no palette we can read, or one
// whose three stops are the same colour however far they are lifted.
var DEFAULT_STOPS = [[133, 13, 41], [239, 204, 69], [67, 242, 161]]

// Themes name their palette either directly or as terminal colour slots. The
// named key wins where a theme defines both, so it leads each list.
var PALETTE_ALIASES = {red: ['red', 'color1'], yellow: ['yellow', 'color3'],
                       green: ['green', 'color2']}

// How far apart the three stops must sit, as a weighted RGB distance, before
// the theme's own colours replace the built-in ones. Measured after lifting,
// never before: a theme can be the right three hues at the wrong three
// saturations, and rejecting that wholesale throws away a usable palette.
var RAMP_SEPARATION_MIN = 80

// Chroma the ramp needs to read as a warning at a glance. The lightness band
// is wide on purpose: it rescues a stop too dark or too pale to see without
// second-guessing a theme that chose a bright red deliberately. A stop below
// the hue floor has no hue at all and borrows the built-in one; the floor sits
// just above zero because only vantablack and white score exactly 0.000 and
// the next lowest stop across 40 themes is 0.041.
var RAMP_MIN_SAT = 0.55
var RAMP_MIN_LIGHT = 0.30
var RAMP_MAX_LIGHT = 0.78
var RAMP_HUE_FLOOR = 0.02

function hexToRgb(hex) {
    var m = /^#([0-9a-fA-F]{6})$/.exec(String(hex || '').replace(/^\s+|\s+$/g, ''))
    if (!m) return null
    var n = parseInt(m[1], 16)
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

// Weighted RGB distance ("redmean"), a cheap stand-in for a perceptual metric.
// Accurate enough to tell three distinct hues from three shades of one mud,
// which is the only judgement the ramp needs it to make.
function separation(a, b) {
    var mean = (a[0] + b[0]) / 2, dr = a[0] - b[0], dg = a[1] - b[1], db = a[2] - b[2]
    return Math.sqrt((2 + mean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - mean) / 256) * db * db)
}

function rgbToHsl(r, g, b) {
    r /= 255; g /= 255; b /= 255
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
    if (s === 0) return [Math.round(l*255), Math.round(l*255), Math.round(l*255)]
    var hi = l < 0.5 ? l * (1 + s) : l + s - l * s
    var lo = 2 * l - hi
    function channel(t) {
        if (t < 0) t += 1
        if (t > 1) t -= 1
        if (t < 1/6) return lo + (hi - lo) * 6 * t
        if (t < 1/2) return hi
        if (t < 2/3) return lo + (hi - lo) * (2/3 - t) * 6
        return lo
    }
    return [Math.round(channel(h+1/3)*255), Math.round(channel(h)*255), Math.round(channel(h-1/3)*255)]
}

// The shell surfaces only foreground, background, accent, urgent and muted, so
// a theme's green and yellow have to come from the colors.toml it ships.
function parsePalette(raw) {
    var found = {}, lines = String(raw || '').split('\n')
    for (var i = 0; i < lines.length; i++) {
        var m = /^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/.exec(lines[i])
        if (m) found[m[1].toLowerCase()] = m[2]
    }
    var out = {}
    for (var role in PALETTE_ALIASES) {
        var keys = PALETTE_ALIASES[role]
        for (var k = 0; k < keys.length; k++) {
            if (found[keys[k]]) { out[role] = found[keys[k]]; break }
        }
    }
    return out
}

// Raise one stop to the chroma the ramp needs while keeping the theme's hue.
function liftStop(rgb, builtin) {
    var a = rgbToHsl(rgb[0], rgb[1], rgb[2])
    var b = rgbToHsl(builtin[0], builtin[1], builtin[2])
    var hue = a[1] < RAMP_HUE_FLOOR ? b[0] : a[0]
    return hslToRgb(hue, Math.max(a[1], RAMP_MIN_SAT),
                    Math.min(Math.max(a[2], RAMP_MIN_LIGHT), RAMP_MAX_LIGHT))
}

// Three stops for the link ramp: the theme's own hues, lifted to a readable
// chroma, and DEFAULT_STOPS only when even lifted they do not separate.
function rampStops(raw) {
    var palette = parsePalette(raw)
    var low = hexToRgb(palette.red), mid = hexToRgb(palette.yellow), high = hexToRgb(palette.green)
    if (!low || !mid || !high) return DEFAULT_STOPS
    low = liftStop(low, DEFAULT_STOPS[0])
    mid = liftStop(mid, DEFAULT_STOPS[1])
    high = liftStop(high, DEFAULT_STOPS[2])
    if (separation(low, mid) < RAMP_SEPARATION_MIN) return DEFAULT_STOPS
    if (separation(mid, high) < RAMP_SEPARATION_MIN) return DEFAULT_STOPS
    return [low, mid, high]
}

function ramp(percent, stops) {
    var s = stops && stops.length === 3 ? stops : DEFAULT_STOPS
    var f = clamp(percent, 0, 100) / 100
    var a = f <= 0.5 ? s[0] : s[1]
    var b = f <= 0.5 ? s[1] : s[2]
    var t = f <= 0.5 ? f * 2 : (f - 0.5) * 2
    return Qt.rgba((a[0]+(b[0]-a[0])*t)/255, (a[1]+(b[1]-a[1])*t)/255, (a[2]+(b[2]-a[2])*t)/255, 1)
}
// Decimal units: network gear and speed tests quote MB/s and Mbit/s in powers of ten.
function rate(bps) {
    var n = Math.max(0, num(bps))
    if (n >= 1e9) return (n/1e9).toFixed(1)+' GB/s'
    if (n >= 1e6) return (n/1e6).toFixed(1)+' MB/s'
    if (n >= 1e3) return (n/1e3).toFixed(1)+' KB/s'
    return n.toFixed(0)+' B/s'
}
function shortRate(bps) {
    var n = Math.max(0, num(bps))
    if (n >= 1e9) return (n/1e9).toFixed(1)+'G'
    if (n >= 1e6) return (n/1e6).toFixed(1)+'M'
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
function size(bytes) {
    var n = Math.max(0, num(bytes))
    if (n >= 1e12) return (n/1e12).toFixed(2)+' TB'
    if (n >= 1e9) return (n/1e9).toFixed(2)+' GB'
    if (n >= 1e6) return (n/1e6).toFixed(1)+' MB'
    if (n >= 1e3) return (n/1e3).toFixed(1)+' KB'
    return n.toFixed(0)+' B'
}
// Compact byte totals for a graph axis, where a full unit will not fit.
function shortSize(bytes) {
    var n = Math.max(0, num(bytes))
    if (n >= 1e12) return (n/1e12).toFixed(1)+'T'
    if (n >= 1e9) return (n/1e9).toFixed(1)+'G'
    if (n >= 1e6) return (n/1e6).toFixed(0)+'M'
    if (n >= 1e3) return (n/1e3).toFixed(0)+'K'
    return n.toFixed(0)+'B'
}
// Rolling windows the usage tab offers. 0 means everything ever recorded.
var RANGES = [3600, 86400, 604800, 2592000, 31536000, 0]
function rangeName(seconds) {
    var names = {3600:'Hour', 86400:'Day', 604800:'Week', 2592000:'Month', 31536000:'Year', 0:'All time'}
    return names[num(seconds)] || 'Hour'
}
function rangeWhen(seconds) {
    var when = {3600:'the last hour', 86400:'the last 24 hours', 604800:'the last 7 days',
                2592000:'the last 30 days', 31536000:'the last 365 days', 0:'everything recorded'}
    return when[num(seconds)] || 'the last hour'
}
// Averaged over the time actually recorded, never over the whole window: a
// fresh install has not been watching for a year and must not imply it has.
// Under a few hours a daily figure is an extrapolation wild enough to alarm
// -- one busy hour reads as a terabyte a day -- so a short window is quoted
// as the rate it actually was.
function pace(bytes, recorded) {
    var s = num(recorded)
    if (s < 300) return '—'
    if (s < 6*3600) return rate(num(bytes)/s)+' average'
    return size(num(bytes)*86400/s)+' a day'
}
// What share of the window was being recorded, as prose rather than a percent.
function coverage(recorded, seconds) {
    var r = num(recorded), s = num(seconds)
    if (s <= 0 || r <= 0) return 'nothing recorded yet'
    if (r >= s*0.995) return 'fully recorded'
    return ago(r)+' recorded of '+ago(s)
}
function mbit(v) {
    if (!has(v) || Number(v) <= 0) return '—'
    var n = Number(v)
    return n >= 1000 ? (n/1000).toFixed(n % 1000 === 0 ? 0 : 1)+' Gbit/s' : n.toFixed(0)+' Mbit/s'
}
// null = no sample yet, negative = probe timed out.
function ms(v) {
    if (!has(v)) return '—'
    var n = Number(v)
    if (n < 0) return 'timeout'
    return (n < 10 ? n.toFixed(1) : n.toFixed(0))+' ms'
}
function dbm(v) { return has(v) ? Math.round(Number(v))+' dBm' : '—' }
function pct(v) { return has(v) ? Number(v).toFixed(1)+'%' : '—' }
function whole(v) { return has(v) ? Math.round(Number(v))+'%' : '—' }
function count(v) {
    var n = num(v)
    return n >= 1e6 ? (n/1e6).toFixed(1)+'M' : n >= 1e4 ? (n/1e3).toFixed(1)+'k' : n.toFixed(0)
}
function perSec(v) { return count(v)+'/s' }
function ago(seconds) {
    var s = Math.max(0, Math.floor(num(seconds)))
    if (s < 60) return s+'s'
    if (s < 3600) return Math.floor(s/60)+'m '+(s%60)+'s'
    if (s < 86400) return Math.floor(s/3600)+'h '+Math.floor(s%3600/60)+'m'
    return Math.floor(s/86400)+'d '+Math.floor(s%86400/3600)+'h'
}
function band(mhz) {
    var v = num(mhz)
    if (!v) return ''
    if (v >= 2400 && v < 2500) return '2.4 GHz'
    if (v >= 4900 && v < 5925) return '5 GHz'
    if (v >= 5925 && v < 7125) return '6 GHz'
    return (v/1000).toFixed(1)+' GHz'
}
// The address without its prefix length: what you actually paste elsewhere.
function bare(addr) { return String(addr || '').split('/')[0] }
function isAddress(value) { return /^[0-9a-fA-F:.]{3,45}$/.test(String(value || '').trim()) }
function security(text) {
    var s = String(text || '').trim()
    if (!s || s === 'Open') return 'Open'
    if (s.indexOf('802.1X') >= 0) return 'Enterprise'
    if (s.indexOf('OWE') >= 0) return 'Enhanced open'
    if (s.indexOf('WPA3') >= 0) return 'WPA3'
    if (s.indexOf('WPA2') >= 0) return 'WPA2'
    if (s.indexOf('WPA1') >= 0 || s.indexOf('WPA') >= 0) return 'WPA'
    return s
}
function kindName(kind) {
    return {wifi: 'Wi-Fi', ethernet: 'Ethernet', tunnel: 'Tunnel', bridge: 'Bridge', loopback: 'Loopback', virtual: 'Virtual'}[kind] || 'Link'
}
// A single 0–100 score the chip colour follows. Offline is red; a captive
// portal or limited connectivity caps at yellow; latency, loss and a weak
// radio each take headroom away.
function health(m) {
    if (!m || !m.warm) return 50
    if (!m.online) return 0
    var h = 100
    var c = m.connectivity || 'unknown'
    if (c === 'portal' || c === 'limited' || c === 'none') h = Math.min(h, 40)
    var p = m.ping || {}
    if (has(p.internet)) {
        if (Number(p.internet) < 0) h -= 55
        else if (Number(p.internet) > 20) h -= Math.min(40, (Number(p.internet)-20)/180*40)
    }
    h -= Math.min(40, num(p.loss)*0.8)
    if (m.wifi && m.wifi.ssid && has(m.wifi.quality) && Number(m.wifi.quality) < 60) h -= (60-Number(m.wifi.quality))*1.2
    return clamp(h, 0, 100)
}
function healthLabel(m) {
    if (!m || !m.warm) return 'WAITING FOR TELEMETRY'
    if (!m.online) return 'NO ROUTE TO THE INTERNET'
    var c = m.connectivity || 'unknown'
    if (c === 'portal') return 'CAPTIVE PORTAL AHEAD'
    if (c === 'limited') return 'LIMITED CONNECTIVITY'
    if (c === 'none') return 'LINK UP · NO INTERNET'
    var p = m.ping || {}
    if (has(p.internet) && Number(p.internet) < 0) return 'INTERNET NOT ANSWERING'
    if (num(p.loss) >= 10) return 'PACKETS ARE GOING MISSING'
    if (has(p.internet) && Number(p.internet) > 120) return 'SLOW PATH TO THE INTERNET'
    if (m.wifi && m.wifi.ssid && has(m.wifi.quality) && Number(m.wifi.quality) < 40) return 'WEAK RADIO SIGNAL'
    return 'CLEAR PATH TO THE INTERNET'
}
function isWifi(m) { return !!(m && m.iface && m.iface.kind === 'wifi' && m.wifi && m.wifi.ssid) }
function readout(m, mode) {
    if (!m || !m.warm) return '—'
    if (!m.online) return 'offline'
    var iface = m.iface || {}, ping = m.ping || {}
    if (mode === 1) return isWifi(m) ? dbm(m.wifi.signal) : mbit(iface.speed)
    if (mode === 2) return ms(has(ping.internet) ? ping.internet : ping.gateway)
    if (mode === 3) return isWifi(m) ? m.wifi.ssid : (iface.connection || iface.name || '—')
    if (mode === 4) return bare((iface.addrs4 && iface.addrs4.length ? iface.addrs4[0] : iface.addrs6 && iface.addrs6.length ? iface.addrs6[0] : 'no address'))
    return '↓ '+tight(m.rates ? m.rates.rx : 0)
}
function modeTag(m, mode) {
    if (!m || !m.warm || !m.online) return 'NETWORK'
    var iface = m.iface || {}, ping = m.ping || {}
    if (mode === 1) return isWifi(m) ? whole(m.wifi.quality)+' SIGNAL' : 'LINK SPEED'
    if (mode === 2) return has(ping.internet) ? 'INTERNET' : 'GATEWAY'
    if (mode === 3) return isWifi(m) ? (m.wifi.band || band(m.wifi.freq))+(m.wifi.channel ? ' · CH '+m.wifi.channel : '') : kindName(iface.kind).toUpperCase()
    if (mode === 4) return String(iface.name || '').toUpperCase()
    return '↑ '+tight(m.rates ? m.rates.tx : 0)
}
// The bar widget must not change width as a reading changes. Every resize
// re-lays out the whole bar section it sits in, and on a full bar the sections
// briefly overlap before the shell settles -- the readout ends up drawn over
// the widget to its right. So each mode whose text changes every sample
// reserves the width of the widest string it can produce. These are floors,
// never limits: the live text still wins if it runs wider, so nothing clips.
// The name and address modes reserve nothing, because they only change when
// the network does and cannot flicker.
function widestReadout(m, mode) {
    if (mode === 1) return isWifi(m) ? '-100 dBm' : '999 Mbit/s'
    // '9999 ms' is wider than 'timeout' and than any latency short of absurd.
    // For throughput, 'M' is the widest unit letter and 99.9 the widest of the
    // five-character readings, so '99.9M' dominates every rate tight() emits.
    if (mode === 2) return '9999 ms'
    if (mode === 3 || mode === 4) return ''
    return '\u2193 99.9M'
}
function widestTag(m, mode) {
    if (mode === 1) return isWifi(m) ? '100% SIGNAL' : 'LINK SPEED'
    if (mode === 2) return 'INTERNET'
    if (mode === 3 || mode === 4) return ''
    return '\u2191 99.9M'
}
function modeName(mode) { return ['Throughput', 'Signal / link speed', 'Latency', 'Network name', 'IP address'][mode] || 'Throughput' }
// Axis ceiling for the history graph: 1–2–5 steps, never below 10 KB/s so a quiet link is not magnified into noise.
function niceMax(v) {
    var n = Math.max(1e4, num(v)*1.15)
    var p = Math.pow(10, Math.floor(Math.log(n)/Math.LN10))
    var f = n/p
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10)*p
}
function niceMs(v) {
    var n = Math.max(20, num(v)*1.15)
    var p = Math.pow(10, Math.floor(Math.log(n)/Math.LN10))
    var f = n/p
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10)*p
}
