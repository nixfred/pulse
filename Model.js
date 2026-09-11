.pragma library

// Helpers for the merged chrome only. Every reading, unit and label still comes
// from the four domain models in sections/, which are the originals unchanged.

function clamp(value, low, high) {
    var n = Number(value)
    if (!isFinite(n)) return low
    return n < low ? low : n > high ? high : n
}

function pageIndex(pages, key) {
    for (var i = 0; i < pages.length; i++) if (pages[i].key === key) return i
    return 0
}
