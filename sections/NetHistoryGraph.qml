import QtQuick
import "NetModel.js" as Model

// Throughput and latency history. Points are
// [ts, rxAvg, rxPeak, txAvg, latency, signal, count, boot]. Download and
// upload share the left axis; latency has its own right axis. Missing time is
// left blank, and gaps or reboots break every trace.
Item {
    id: root
    // False drops the axis labels and their gutters, for the Overview
    // cards where the chart is too short to carry them.
    property bool axesVisible: true
    property var historyData: ({points:[], seconds:3600, now:0, bucket:15, peakRx:0, peakTx:0, peakLatency:0})
    property color tint: '#43f2a1'
    // Theme surfaces, handed down by the panel. Upload takes the theme accent
    // and latency the urgent colour, which keeps all three traces apart on any
    // theme; download keeps the health tint it shares with the chip.
    property color upTint: '#8d9dff'
    property color latencyTint: '#f0ba82'
    property color axisText: '#7e959f'
    property color gridLine: '#233039'
    property color tipBackground: '#17232d'
    property color tipBorder: '#40525f'
    property color tipText: '#edf5f7'
    property int hoverIndex: -1
    readonly property int leftAxis: axesVisible ? 52 : 0
    readonly property int rightAxis: axesVisible ? 40 : 0
    readonly property var points: historyData && historyData.points ? historyData.points : []
    readonly property var hoverPoint: hoverIndex >= 0 && hoverIndex < points.length ? points[hoverIndex] : null
    readonly property real ceiling: Model.niceMax(Math.max(historyData.peakRx || 0, historyData.peakTx || 0))
    readonly property real msCeiling: Model.niceMs(historyData.peakLatency || 0)
    // History keeps landing every 15s while the dashboard is closed. Painting
    // for it then is wasted; the graph catches up when it becomes visible.
    function repaint() { if (root.visible) graph.requestPaint() }
    onHistoryDataChanged: { hoverIndex=-1; repaint() }
    onTintChanged: repaint()
    onVisibleChanged: repaint()
    function plotWidth() { return Math.max(1, width-leftAxis-rightAxis) }
    function xFor(ts) { return leftAxis+plotWidth()*(ts-(historyData.now-historyData.seconds))/historyData.seconds }
    Canvas {
        id: graph
        anchors.fill: parent
        onWidthChanged: root.repaint()
        Connections { target: root; function onAxesVisibleChanged() { root.repaint() } }
        onHeightChanged: root.repaint()
        onPaint: {
            var c=getContext('2d'), w=root.plotWidth(), h=height-(root.axesVisible?26:4), x0=root.leftAxis
            c.reset();c.clearRect(0,0,width,height)
            c.font='10px sans-serif'
            for(var line=0;line<=4;line++){
                var y=8+(h-8)*line/4
                c.strokeStyle=root.gridLine;c.lineWidth=1;c.beginPath();c.moveTo(x0,y);c.lineTo(x0+w,y);c.stroke()
                if(root.axesVisible){
                    c.fillStyle=root.axisText;c.textAlign='right';c.fillText(Model.shortRate(root.ceiling*(1-line/4))+'/s',x0-4,y+3)
                    c.fillStyle=root.latencyTint;c.textAlign='left';c.fillText(Math.round(root.msCeiling*(1-line/4))+'ms',x0+w+4,y+3)
                }
            }
            function yRate(v){return 8+(h-8)*(1-Model.clamp(v,0,root.ceiling)/root.ceiling)}
            function yMs(v){return 8+(h-8)*(1-Model.clamp(v,0,root.msCeiling)/root.msCeiling)}
            var pts=root.points
            function trace(index, style, widthPx, yFn, dashed){
                c.lineWidth=widthPx;c.strokeStyle=style;c.setLineDash(dashed?[3,3]:[])
                c.beginPath();var pen=false
                for(var i=0;i<pts.length;i++){
                    var p=pts[i], v=p[index]
                    if(v===null||v===undefined){pen=false;continue}
                    var x=root.xFor(p[0]), y=yFn(v)
                    if(!pen || p[0]-pts[i-1][0]>root.historyData.bucket*2.5 || p[7]!==pts[i-1][7]) c.moveTo(x,y); else c.lineTo(x,y)
                    pen=true
                }
                c.stroke();c.setLineDash([])
            }
            trace(2,Qt.alpha(root.tint,0.28),1,yRate,false)
            trace(4,root.latencyTint,1,yMs,true)
            trace(3,root.upTint,1.4,yRate,false)
            trace(1,root.tint,2.2,yRate,false)
            if(pts.length){
                var last=pts[pts.length-1]
                c.fillStyle=root.tint;c.beginPath();c.arc(root.xFor(last[0]),yRate(last[1]||0),3,0,Math.PI*2);c.fill()
            }
            if(root.axesVisible){
                c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',x0,height-3)
                c.textAlign='right';c.fillText('now',x0+w,height-3)
            }
        }
    }
    Rectangle {
        visible: root.hoverPoint !== null
        x: root.hoverPoint ? Math.max(root.leftAxis,Math.min(root.width-root.rightAxis,root.xFor(root.hoverPoint[0]))) : 0
        y: 8; width: 1; height: parent.height-34; color: root.axisText
    }
    Rectangle {
        visible: root.hoverPoint !== null
        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
        width: hoverText.implicitWidth+20; height: 27; radius: 7; color:root.tipBackground;border.color:root.tipBorder
        Text {
            id: hoverText; anchors.centerIn:parent; color:root.tipText;font.pixelSize:11
            text: {
                var p=root.hoverPoint
                if(!p) return ''
                return Qt.formatDateTime(new Date(p[0]*1000),'ddd h:mm AP')+'  ·  ↓ '+Model.rate(p[1])+'  ·  ↑ '+Model.rate(p[3])+'  ·  '+(p[4]===null||p[4]===undefined?'no ping':Model.ms(p[4]))+(p[5]===null||p[5]===undefined?'':'  ·  signal '+Model.whole(p[5]))
            }
        }
    }
    MouseArea {
        anchors.fill:parent; hoverEnabled:true; acceptedButtons:Qt.NoButton
        onExited:root.hoverIndex=-1
        onPositionChanged:function(mouse){
            var wanted=root.historyData.now-root.historyData.seconds+(mouse.x-root.leftAxis)/root.plotWidth()*root.historyData.seconds, best=-1, distance=Infinity
            for(var i=0;i<root.points.length;i++){var d=Math.abs(root.points[i][0]-wanted);if(d<distance){distance=d;best=i}}
            root.hoverIndex=distance<root.historyData.bucket*3?best:-1
        }
    }
}
