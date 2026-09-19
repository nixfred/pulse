.pragma library

// Shared helpers for the merged Pulse chrome and the four domain sections.
// Every reading, unit and label still comes from the four domain models in
// sections/, which remain the originals. This library only centralises the
// cross-cutting plumbing the audit flagged: safe JSON parsing, numeric
// guards, file-URL decoding, version resolution, panel geometry limits and
// stale thresholds.
//
// Locale note (audit #26): toFixed() is intentionally locale-independent in
// QML/JS (always '.' decimal), so readouts keep toFixed as-is. No
// locale-aware formatting is applied; thousands separators are never emitted.

// ---- panel geometry (audit #1, #11, #24) -------------------------------
var PANEL_MIN = 640
var PANEL_MAX = 2000
var PANEL_FLOOR_WIDE = 1240  // preferred floor when the screen allows it
var CAPTION_CEIL = 110       // max bar-caption width per cell (px)
var STATUS_EXPIRY_MS = 8000  // actionStatus lifetime everywhere

// ---- stale thresholds (audit #1, #29) ----------------------------------
var STALE_CPU_S = 15
var STALE_RAM_S = 15
var STALE_DISK_S = 15
var STALE_NET_S = 15   // unified: was 12s on Net, now 15s like the rest

// ---- history ranges ------------------------------------------------------
var RANGE_HOUR = 3600
var RANGE_DAY = 86400
var RANGE_WEEK = 604800
var VALID_RANGES = [3600, 86400, 604800]

function clamp(value, low, high) {
    var n = Number(value)
    if (!isFinite(n)) return low
    return n < low ? low : n > high ? high : n
}

function pageIndex(pages, key) {
    for (var i = 0; i < pages.length; i++) if (pages[i].key === key) return i
    return 0
}

// ---- safe JSON (audit #1, #2) -------------------------------------------
// Never throws: returns fallback (default null) on empty/bad input.
function safeParse(s, fallback) {
    if (fallback === undefined) fallback = null
    try {
        if (s === null || s === undefined || s === '') return fallback
        var v = JSON.parse(s)
        return v === undefined ? fallback : v
    } catch (e) {
        return fallback
    }
}

// ---- numeric guards (audit #1) -------------------------------------------
function num(v, fallback) {
    if (fallback === undefined) fallback = 0
    var n = Number(v)
    return isFinite(n) ? n : fallback
}

function has(v) {
    return v !== null && v !== undefined && isFinite(Number(v))
}

// ---- file URLs (audit #1, #17) -------------------------------------------
// Qt.resolvedUrl() yields file:// URLs possibly with %20 etc. Strip the
// scheme and decode so FileView/helper paths with spaces resolve.
function filePath(url) {
    try {
        var s = decodeURIComponent(String(url))
        return s.replace(/^file:\/\//, '')
    } catch (e) {
        return String(url).replace(/^file:\/\//, '')
    }
}

// ---- versions (audit #1, #18) ---------------------------------------------
// Single version resolution: registry entry wins, then the manifest file
// text beside the plugin, then ''. No hardcoded version strings in QML.
function versionFrom(text) {
    var m = safeParse(text, null)
    if (m && m.version) return String(m.version)
    return ''
}

function resolveVersion(registryEntry, fileManifest) {
    if (registryEntry && registryEntry.version) return String(registryEntry.version)
    if (fileManifest && fileManifest.version) return String(fileManifest.version)
    return ''
}

// ---- IPC validation helpers (audit #4, #5, #6, #7, #30) -------------------
// Normalise a loosely-typed boolean from IPC: 'true'/'1' => true,
// 'false'/'0'/'' => false, numbers via !!, otherwise !!value.
function toBool(v) {
    if (typeof v === 'string') {
        var s = v.trim().toLowerCase()
        if (s === 'true' || s === '1' || s === 'yes' || s === 'on') return true
        if (s === 'false' || s === '0' || s === '' || s === 'no' || s === 'off') return false
    }
    if (typeof v === 'number') return v !== 0 && isFinite(v) ? !!v : false
    return !!v
}

function isValidRange(v) {
    return VALID_RANGES.indexOf(Number(v)) >= 0
}

// ---- URL validation (audit #27) -------------------------------------------
function isHttps(url) {
    return /^https:\/\//.test(String(url || ''))
}

// ---- null-safe theme roles (audit #25) --------------------------------------
// qs.Commons / qs.Ui singletons are always present in the shell, but an
// individual role can be null on a future theme API or in headless tests.
// role(obj, key, fallback) keeps the binding alive with a fallback palette
// instead of breaking it. Covers Color.popups.text/background/border,
// Color.bar.background, Color.tooltip.* and Style.* at the call sites.
function role(obj, key, fallback) {
    try {
        if (!obj) return fallback
        var v = obj[key]
        return (v === undefined || v === null) ? fallback : v
    } catch (e) {
        return fallback
    }
}
