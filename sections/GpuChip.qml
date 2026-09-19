import QtQuick
import "GpuModel.js" as Model

// A graphics die: a square package with a grid of compute blocks that light
// with utilisation, and a memory band down the side that fills with VRAM. The
// two readings a GPU is judged on are the two things the chip draws.
Item {
    id: root
    property real busy: 0
    // VRAM in use, 0..100. Drawn as its own band because a card can sit at 0%
    // busy and still be completely unusable for the next job.
    property real vram: 0
    property bool animate: true
    property bool compact: false
    property color tint: Model.ramp(busy)
    // The memory band keeps its own colour: it is a different question from
    // "is it working", and a full card should read as a warning while the
    // compute grid is still calmly green.
    property color memTint: Model.ramp(vram)
    // The chip's own body. The panel passes the theme's popup background so the
    // silicon reads as a cut-out of the panel rather than a fixed dark square.
    property color body: '#0b141b'
    property color glint: '#edf5f7'
    property real phase: 0
    implicitWidth: compact ? 28 : 160
    implicitHeight: compact ? 25 : 160
    // One revolution every 5.8s, advanced by the repaint tick itself.
    readonly property real phaseStep: tick.interval / 5800
    // Painting is coalesced onto one 10Hz tick and stops while invisible. Do
    // not drive phase from an animation: that repaints at display rate.
    Timer {
        id: tick
        interval: 100; repeat: true
        running: root.animate && root.visible
        onTriggered: { root.phase = (root.phase + root.phaseStep) % 1; canvas.requestPaint() }
    }
    function repaint() { if (root.visible) canvas.requestPaint() }
    onTintChanged: repaint()
    onMemTintChanged: repaint()
    onBodyChanged: repaint()
    onBusyChanged: repaint()
    onVramChanged: repaint()
    onVisibleChanged: repaint()
    Canvas {
        id: canvas
        anchors.fill: parent
        onWidthChanged: root.repaint()
        onHeightChanged: root.repaint()
        onPaint: {
            var c = getContext('2d'), w = width, h = height
            c.reset(); c.clearRect(0, 0, w, h)
            var cx = w / 2, cy = h / 2, size = Math.min(w, h)
            var pack = size * (root.compact ? 0.62 : 0.5)
            var x = cx - pack / 2, y = cy - pack / 2, t = root.phase * Math.PI * 2
            var load = Model.clamp(root.busy, 0, 100) / 100
            var fill = Model.clamp(root.vram, 0, 100) / 100

            // The aura breathes with load, so a working card reads as working
            // from across the bar without needing the number.
            var aura = c.createRadialGradient(cx, cy, pack * 0.1, cx, cy, size * 0.5)
            aura.addColorStop(0, Qt.alpha(root.tint, 0.20 + 0.30 * load))
            aura.addColorStop(0.6, Qt.alpha(root.tint, 0.10 + 0.14 * load * (0.8 + 0.2 * Math.sin(t))))
            aura.addColorStop(1, 'transparent')
            c.fillStyle = aura; c.fillRect(0, 0, w, h)

            c.fillStyle = root.body
            c.fillRect(x, y, pack, pack)

            // Glow as a few widening, fading strokes, never shadowBlur: the
            // blur is rasterised on the GUI thread and cost 30-70 ms a paint at
            // card size, which is what made this panel hesitate as it opened.
            var haloBase = root.compact ? 1.2 : 2
            c.save(); c.strokeStyle = root.tint
            for (var halo = (root.compact ? 2 : 4); halo > 0; halo--) {
                c.globalAlpha = 0.09
                c.lineWidth = haloBase + halo * (root.compact ? 1.2 : 2.4)
                c.strokeRect(x, y, pack, pack)
            }
            c.restore()
            c.strokeStyle = root.tint; c.lineWidth = haloBase
            c.strokeRect(x, y, pack, pack)

            // Compute blocks. A GPU is a grid of identical units, so the die is
            // drawn as one: the share that is lit is the utilisation, and the
            // leading edge shimmers so a busy card never looks like a still
            // image.
            var cols = root.compact ? 4 : 8
            var gap = pack * (root.compact ? 0.06 : 0.045)
            var cell = (pack - gap * (cols + 1)) / cols
            var total = cols * cols
            var litCount = Math.round(total * load)
            for (var i = 0; i < total; i++) {
                var col = i % cols, row = Math.floor(i / cols)
                var bx = x + gap + col * (cell + gap)
                var by = y + gap + row * (cell + gap)
                // Fill from the bottom row up, so the die fills like a gauge.
                var rank = (cols - 1 - row) * cols + col
                if (rank < litCount) {
                    var edge = rank >= litCount - cols
                    var shimmer = edge ? 0.55 + 0.45 * Math.abs(Math.sin(t + col)) : 1
                    c.fillStyle = Qt.alpha(root.tint, 0.45 + 0.5 * shimmer)
                } else {
                    c.fillStyle = Qt.alpha(root.glint, 0.10)
                }
                c.fillRect(bx, by, cell, cell)
            }

            // Memory band: the VRAM gauge, outside the package on the right,
            // the way memory sits beside the die on a board.
            var bandW = root.compact ? Math.max(2.5, pack * 0.14) : pack * 0.13
            var bandX = x + pack + (root.compact ? 2.5 : 8)
            if (bandX + bandW <= w) {
                c.fillStyle = Qt.alpha(root.glint, 0.12)
                c.fillRect(bandX, y, bandW, pack)
                var top = y + pack * (1 - fill)
                var grad = c.createLinearGradient(0, y, 0, y + pack)
                grad.addColorStop(0, Qt.alpha(root.memTint, 0.95))
                grad.addColorStop(1, Qt.alpha(root.memTint, 0.45))
                c.fillStyle = grad
                c.fillRect(bandX, top, bandW, pack - (top - y))
                c.strokeStyle = Qt.alpha(root.memTint, 0.8); c.lineWidth = 1
                c.strokeRect(bandX, y, bandW, pack)
            }

            if (!root.compact) {
                // Package pins, with traffic running along them while the card
                // works. Idle silicon gets a still chip.
                c.strokeStyle = root.tint; c.lineWidth = 2
                for (var pin = 0; pin < 4; pin++) {
                    var p = pack * (pin + 1) / 5, len = pack * 0.15
                    c.beginPath()
                    c.moveTo(x + p, y - len); c.lineTo(x + p, y)
                    c.moveTo(x + p, y + pack); c.lineTo(x + p, y + pack + len)
                    c.moveTo(x - len, y + p); c.lineTo(x, y + p)
                    c.stroke()
                    var progress = (root.phase + pin / 4) % 1
                    c.fillStyle = Qt.alpha(root.tint, (1 - progress * 0.5) * (0.25 + 0.75 * load))
                    c.beginPath(); c.arc(x + p, y - len - progress * pack * 0.28, 1.7, 0, Math.PI * 2); c.fill()
                }
            }
        }
    }
}
