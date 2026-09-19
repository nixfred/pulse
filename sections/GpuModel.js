.pragma library

// Readings, units and labels for the GPU domain.
//
// The theme ramp machinery (palette parsing, the three colour stops, the heat
// colour) is identical in every domain and already written once in CpuModel.js,
// so this imports it rather than carrying a fifth copy of 140 lines that would
// then have to be kept in step. Only the parts that are actually specific to
// graphics live here: what the four readouts say, and how a GPU's units read.
.import "CpuModel.js" as Shared

var clamp = Shared.clamp
var rampStops = Shared.rampStops
var heatColor = Shared.heatColor

// Colour follows pressure, not headroom: a GPU at 5% busy is comfortable and a
// GPU at 95% is the constraint, which is the opposite direction to the memory
// chip's "how much is free". Inverting here keeps every chip in the panel
// agreeing that green is fine and hot is not.
function ramp(percent, stops) {
    return Shared.ramp(100 - clamp(percent, 0, 100), stops)
}

function pct(v) {
    return v === null || v === undefined || isNaN(Number(v)) ? '—' : (Number(v)).toFixed(1) + '%'
}
function whole(v) {
    return v === null || v === undefined || isNaN(Number(v)) ? '—' : Math.round(Number(v)) + '%'
}
function temp(v) {
    return v === null || v === undefined || isNaN(Number(v)) ? '—' : Math.round(Number(v)) + '°C'
}
function watts(v) {
    return v === null || v === undefined || isNaN(Number(v)) ? '—' : (Number(v)).toFixed(1) + ' W'
}
function mhz(v) {
    if (v === null || v === undefined || isNaN(Number(v))) return '—'
    var n = Number(v)
    return n >= 1000 ? (n / 1000).toFixed(2) + ' GHz' : Math.round(n) + ' MHz'
}
function size(bytes) {
    if (bytes === null || bytes === undefined || isNaN(Number(bytes))) return '—'
    var units = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, n = Number(bytes)
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + units[i]
}
// Seconds-per-minute of a throttle counter, which is what the collector reports
// rather than the counter itself. 60 of 60 is "the whole time".
function perMinute(v) {
    return v === null || v === undefined || isNaN(Number(v)) ? '—' : (Number(v)).toFixed(0) + 's/min'
}

function vendorName(vendor) {
    return vendor === 'nvidia' ? 'NVIDIA' : vendor === 'amd' ? 'AMD' : vendor === 'intel' ? 'Intel' : ''
}

// P-states run P0 (flat out) to P12 (deeply idle), which is backwards from
// every other number in this panel, so it is spelled out rather than shown raw.
function pstate(v) {
    if (v === null || v === undefined || isNaN(Number(v))) return '—'
    var n = Number(v)
    return 'P' + n + (n === 0 ? ' · maximum' : n >= 8 ? ' · idle' : ' · partial')
}

function throttleName(key) {
    var names = {
        idle: 'Idle', appClocks: 'Application clock setting', swPowerCap: 'Power cap',
        hwSlowdown: 'Hardware slowdown', syncBoost: 'Sync boost',
        swThermal: 'Thermal (software)', hwThermal: 'Thermal (hardware)',
        hwPowerBrake: 'Power brake', displayClock: 'Display clock setting'
    }
    return names[key] || key
}

// ---- the four bar readouts ----------------------------------------------
// Busy leads because it is what a GPU is for. VRAM is second because on a
// machine that runs models locally it is the reading that actually stops you:
// a full card refuses the next load while sitting at 0% busy.
function readout(g, mode) {
    if (!g || !g.warm) return '—'
    if (mode === 1) return pct(g.memUsedPct)
    if (mode === 2) return temp(g.tempC)
    if (mode === 3) return watts(g.powerW)
    return pct(g.busyPct)
}
function modeName(mode) { return ['% busy', 'VRAM used', 'Temperature', 'Power draw'][mode] || '% busy' }
function modeTag(mode) { return ['BUSY', 'VRAM', 'TEMP', 'POWER'][mode] || 'BUSY' }

// The one-line verdict under the headline on the Overview card.
function health(g, stale) {
    if (stale || !g || !g.warm) return 'RECORDER OFFLINE'
    if (!g.present) return 'NO GPU FOUND'
    if (typeof g.memUsedPct === 'number' && g.memUsedPct >= 95) return 'VRAM IS FULL'
    if ((g.throttleActive || []).length) return 'BEING HELD BACK'
    if (typeof g.tempC === 'number' && g.tempC >= 87) return 'RUNNING HOT'
    if (typeof g.busyPct === 'number' && g.busyPct >= 90) return 'FLAT OUT'
    if (typeof g.memUsedPct === 'number' && g.memUsedPct >= 85) return 'VRAM IS TIGHT'
    if (typeof g.busyPct === 'number' && g.busyPct >= 50) return 'WORKING'
    return 'PLENTY IN HAND'
}

function recorderStatus(actionStatus, stale, present, reason, when) {
    if (actionStatus) return actionStatus
    if (stale) return 'Telemetry is offline. Check the gpu-pulse user service.'
    if (!present) return 'No GPU reported telemetry on this machine' + (reason ? ': ' + reason : '') + '.'
    return 'LIVE · updated ' + when + '  ·  History stays on this machine  ·  Esc closes'
}
