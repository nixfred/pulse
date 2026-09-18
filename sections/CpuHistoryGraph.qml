import QtQuick
import "CpuModel.js" as Model

Item {
    id: root
    // False drops the axis labels and their gutters, for the Overview
    // cards where the chart is too short to carry them.
    property bool axesVisible: true
    property var historyData: ({points:[], seconds:3600, now:0, bucket:15})
    property color tint: '#43f2a1'
    property color heat: '#ffa86b'
    // Chrome is handed down by the panel so the graph follows the Omarchy
    // theme. The defaults keep it standalone for the widget tests, which
    // instantiate it without the shell singletons. Gridlines, axis labels and
    // the hover chip are all derived from `ink` so one colour drives the lot.
    property color ink: '#edf5f7'
    property color surface: '#17232d'
    readonly property color grid: Qt.alpha(ink, 0.17)
    readonly property color axis: Qt.alpha(ink, 0.58)
    property string fontFamily: 'sans-serif'
    property int hoverIndex: -1
    // Clicking pins the hover chip in place (audit #28); clicking again (or
    // empty space) releases it. While pinned, mouse moves do not retarget.
    property bool hoverPinned: false
    readonly property var points: historyData.points || []
    readonly property var hoverPoint: points[hoverIndex] || null
    // Audit #16: a zero/missing window must never divide by zero.
    readonly property real span: Math.max(1, Number(historyData.seconds) || 3600)
    readonly property real bucket: Math.max(1, Number(historyData.bucket) || 15)
    // History keeps landing every 15s while the dashboard is closed. Painting
    // for it then is wasted; the graph catches up when it becomes visible.
    function repaint() { if (root.visible) graph.requestPaint() }
    onHistoryDataChanged: { hoverIndex=-1; hoverPinned=false; repaint() }
    onTintChanged: repaint()
    onHeatChanged: repaint()
    onInkChanged: repaint()
    onVisibleChanged: repaint()
    Canvas {
        id: graph
        anchors.fill: parent
        onWidthChanged: root.repaint()
        Connections { target: root; function onAxesVisibleChanged() { root.repaint() } }
        onHeightChanged: root.repaint()
        onPaint: {
            var gutter=root.axesVisible?38:0, foot=root.axesVisible?26:4
            var c=getContext('2d'), w=width-gutter, h=height-foot
            c.reset();c.clearRect(0,0,width,height)
            c.font='10px "'+root.fontFamily+'"';c.textAlign='right'
            for(var line=0;line<=4;line++){
                var y=8+(h-8)*line/4
                c.strokeStyle=root.grid;c.lineWidth=1;c.beginPath();c.moveTo(0,y);c.lineTo(w,y);c.stroke()
                if(root.axesVisible){c.fillStyle=root.axis;c.fillText(String(100-line*25),width,y+3)}
            }
            function xAt(p){return w*(p[0]-(root.historyData.now-root.span))/root.span}
            function yAt(v){return 8+(h-8)*(1-Model.clamp(v,0,100)/100)}
            var pts=root.points
            // Empty elapsed time stays empty. Gaps and reboots break every trace.
            // NaN readings are skipped, never plotted at 0 (audit #16).
            // Column 1 is average busy, 2 the bucket peak, 3 the package temperature.
            for(var metric=1;metric<=3;metric++){
                c.lineWidth=metric===1?2.2:1
                c.strokeStyle=metric===3?root.heat:metric===2?Qt.alpha(root.tint,0.28):root.tint
                c.beginPath()
                var pen=false
                for(var i=0;i<pts.length;i++){
                    var p=pts[i], v=p[metric]
                    if(typeof v!=='number'||!isFinite(v)){pen=false;continue}
                    if(metric===3 && !(p[3]>0)) { pen=false;continue }
                    var x=xAt(p), y=yAt(v)
                    if(!pen || p[0]-pts[i-1][0]>root.bucket*2.5 || p[6]!==pts[i-1][6] || (metric===3 && !(pts[i-1][3]>0))) c.moveTo(x,y)
                    else c.lineTo(x,y)
                    pen=true
                }
                c.stroke()
            }
            if(pts.length){
                var last=pts[pts.length-1]
                c.fillStyle=root.tint;c.beginPath();c.arc(xAt(last),yAt(last[1]),3,0,Math.PI*2);c.fill()
            }
            if(root.axesVisible){
                c.fillStyle=root.axis;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',0,height-3)
                c.textAlign='right';c.fillText('now',w,height-3)
            }
        }
    }
    Rectangle {
        visible: root.hoverPoint !== null
        x: root.hoverPoint ? Math.max(0,Math.min(parent.width-38,(root.hoverPoint[0]-(root.historyData.now-root.span))/root.span*(parent.width-38))) : 0
        y: 8; width: 1; height: parent.height-34; color: root.axis
    }
    Rectangle {
        visible: root.hoverPoint !== null
        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
        width: hoverText.implicitWidth+20; height: 27; radius: 7; color:root.surface;border.color:Qt.alpha(root.ink,0.32)
        Text {
            id: hoverText; anchors.centerIn:parent; color:root.ink;font.family:root.fontFamily;font.pixelSize:11
            text: {
                var p=root.hoverPoint
                if(!p) return ''
                return Qt.formatDateTime(new Date(p[0]*1000),'ddd h:mm AP')+'  ·  CPU '+Model.pct(p[1])+'  ·  peak '+Model.pct(p[2])+'  ·  '+(p[3]>0?Model.temp(p[3]):'no temp')
            }
        }
    }
    MouseArea {
        anchors.fill:parent; hoverEnabled:true; acceptedButtons:Qt.LeftButton
        // Clicks still reach the Overview card behind the graph (which opens
        // the domain): pinning the hover must not swallow them.
        propagateComposedEvents: true
        onExited:{ if(!root.hoverPinned) root.hoverIndex=-1 }
        onClicked:function(mouse){ if(root.hoverIndex>=0) root.hoverPinned=true; else root.hoverPinned=false; mouse.accepted=false }
        onPositionChanged:function(mouse){
            if(root.hoverPinned) return
            var wanted=root.historyData.now-root.span+mouse.x/(width-38)*root.span, best=-1, distance=Infinity
            for(var i=0;i<root.points.length;i++){var d=Math.abs(root.points[i][0]-wanted);if(d<distance){distance=d;best=i}}
            root.hoverIndex=distance<root.bucket*3?best:-1
        }
    }
}
