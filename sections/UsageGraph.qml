import QtQuick
import "NetModel.js" as Model

// Bytes moved per bucket, download at the base with upload stacked on top.
// Points are [bucketStart, rxBytes, txBytes]. A bucket that was never recorded
// is absent rather than zero, so a gap in the bars is a gap in the recording
// and not a quiet hour.
Item {
    id: root
    property var usageData: ({points:[], seconds:3600, start:0, now:0, bucket:60, peak:0})
    property color tint: '#43f2a1'
    // Theme surfaces, handed down by the panel; download keeps the health tint.
    property color upTint: '#8d9dff'
    property color axisText: '#7e959f'
    property color gridLine: '#233039'
    property color baseLine: '#33454f'
    property color tipBackground: '#17232d'
    property color tipBorder: '#40525f'
    property color tipText: '#edf5f7'
    property int hoverIndex: -1
    readonly property int leftAxis: 56
    readonly property int rightPad: 8
    readonly property var points: usageData && usageData.points ? usageData.points : []
    readonly property var hoverPoint: hoverIndex >= 0 && hoverIndex < points.length ? points[hoverIndex] : null
    readonly property real bucket: Math.max(1, usageData.bucket || 60)
    readonly property real span: Math.max(bucket, (usageData.now || 0) - (usageData.start || 0))
    readonly property real ceiling: Model.niceMax(usageData.peak || 0)
    // Usage lands every 15s whether or not anyone is looking. Painting for a
    // closed dashboard is wasted; the bars catch up on becoming visible.
    function repaint() { if (root.visible) graph.requestPaint() }
    onUsageDataChanged: { hoverIndex = -1; repaint() }
    onTintChanged: repaint()
    onVisibleChanged: repaint()
    function plotWidth() { return Math.max(1, width - leftAxis - rightPad) }
    function xFor(ts) { return leftAxis + plotWidth()*(ts - (usageData.start || 0))/span }
    // Bars butt up against each other at a hairline, so a solid run of
    // recording reads as solid rather than as a picket fence.
    function barWidth() { return Math.max(1, plotWidth()*bucket/span - 1) }
    // The tooltip names the whole bucket, span and all, because that is what
    // the number under the cursor covers.
    function bucketLabel(ts) {
        var b = root.bucket, from = new Date(ts*1000)
        if (b < 3600) return Qt.formatDateTime(from, 'h:mm AP')
        if (b < 86400) return Qt.formatDateTime(from, 'ddd h AP') + ' – ' + Qt.formatDateTime(new Date((ts + b)*1000), 'h AP')
        if (b < 604800) return Qt.formatDateTime(from, 'ddd d MMM')
        return Qt.formatDateTime(from, 'd MMM') + ' – ' + Qt.formatDateTime(new Date((ts + b - 1)*1000), 'd MMM')
    }
    // The axis only has to say where the window starts, so it names an instant
    // at whatever precision the window makes unambiguous.
    function axisLabel(ts) {
        var d = new Date(ts*1000)
        if (root.span <= 86400) return Qt.formatDateTime(d, 'h:mm AP')
        if (root.span <= 604800) return Qt.formatDateTime(d, 'ddd h AP')
        return Qt.formatDateTime(d, 'd MMM')
    }
    Canvas {
        id: graph
        anchors.fill: parent
        onWidthChanged: root.repaint()
        onHeightChanged: root.repaint()
        onPaint: {
            var c = getContext('2d'), w = root.plotWidth(), h = height - 26, x0 = root.leftAxis, base = h
            c.reset(); c.clearRect(0, 0, width, height)
            c.font = '10px sans-serif'
            for (var line = 0; line <= 4; line++) {
                var y = 8 + (h - 8)*line/4
                c.strokeStyle = root.gridLine; c.lineWidth = 1
                c.beginPath(); c.moveTo(x0, y); c.lineTo(x0 + w, y); c.stroke()
                c.fillStyle = root.axisText; c.textAlign = 'right'
                c.fillText(Model.shortSize(root.ceiling*(1 - line/4)), x0 - 5, y + 3)
            }
            function yFor(v) { return 8 + (h - 8)*(1 - Model.clamp(v, 0, root.ceiling)/root.ceiling) }
            var pts = root.points, bw = root.barWidth()
            for (var i = 0; i < pts.length; i++) {
                var p = pts[i], x = root.xFor(p[0]), hot = i === root.hoverIndex
                var yRx = yFor(p[1]), yTop = yFor(p[1] + p[2])
                c.fillStyle = hot ? Qt.lighter(root.tint, 1.25) : root.tint
                c.fillRect(x, yRx, bw, Math.max(p[1] > 0 ? 1 : 0, base - yRx))
                c.fillStyle = hot ? Qt.lighter(root.upTint, 1.25) : root.upTint
                c.fillRect(x, yTop, bw, Math.max(p[2] > 0 ? 1 : 0, yRx - yTop))
            }
            c.strokeStyle = root.baseLine; c.lineWidth = 1
            c.beginPath(); c.moveTo(x0, base + 0.5); c.lineTo(x0 + w, base + 0.5); c.stroke()
            c.fillStyle = root.axisText; c.textAlign = 'left'
            c.fillText(root.axisLabel(root.usageData.start || 0), x0, height - 3)
            c.textAlign = 'right'; c.fillText('now', x0 + w, height - 3)
        }
    }
    Rectangle {
        visible: root.hoverPoint !== null
        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
        width: hoverText.implicitWidth + 20; height: 27; radius: 7; color: root.tipBackground; border.color: root.tipBorder
        Text {
            id: hoverText; anchors.centerIn: parent; color: root.tipText; font.pixelSize: 11; textFormat: Text.PlainText
            text: {
                var p = root.hoverPoint
                if (!p) return ''
                return root.bucketLabel(p[0]) + '  ·  ↓ ' + Model.size(p[1]) + '  ·  ↑ ' + Model.size(p[2]) + '  ·  ' + Model.size(p[1] + p[2]) + ' total'
            }
        }
    }
    MouseArea {
        anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton
        onExited: root.hoverIndex = -1
        onPositionChanged: function(mouse) {
            var wanted = (root.usageData.start || 0) + (mouse.x - root.leftAxis)/root.plotWidth()*root.span, best = -1
            for (var i = 0; i < root.points.length; i++) {
                var t = root.points[i][0]
                if (wanted >= t && wanted < t + root.bucket) { best = i; break }
            }
            root.hoverIndex = best
        }
    }
}
