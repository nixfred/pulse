import QtQuick
import "DiskModel.js" as Model

// Throughput, capacity and busy history. Points are
// [ts, readAvg, readPeak, writeAvg, usedPct, busyPct, count, boot]. Read and
// write share the left axis; the two percentages have their own right axis.
// Missing time is left blank, and gaps or reboots break every trace.
Item {
    id: root
    property var historyData: ({points:[], seconds:3600, now:0, bucket:15, peakRead:0, peakWrite:0})
    property color tint: Model.RAMP_FALLBACK.high
    // Chrome the panel supplies from the active theme. The defaults are the
    // colours the graph shipped with, so it still stands up on its own. Write
    // takes the theme accent and busy the warning stop of the ramp, which
    // keeps every trace apart on any theme; read keeps the tint it shares
    // with the chip and used capacity is the text colour, dashed.
    property color writeTint: '#8d9dff'
    property color busyTint: '#efcc45'
    property color usedTint: '#c3d3dc'
    property color grid: '#233039'
    property color axisText: '#7e959f'
    property color crosshair: '#71878f'
    property color hoverBackground: '#17232d'
    property color hoverBorder: '#40525f'
    property color hoverForeground: '#edf5f7'
    property string fontFamily: 'sans-serif'
    property int hoverIndex: -1
    readonly property int leftAxis: 46
    readonly property int rightAxis: 34
    readonly property var points: historyData && historyData.points ? historyData.points : []
    readonly property var hoverPoint: hoverIndex >= 0 && hoverIndex < points.length ? points[hoverIndex] : null
    readonly property real ceiling: Model.niceMax(Math.max(historyData.peakRead || 0, historyData.peakWrite || 0))
    // History keeps landing every 15s while the dashboard is closed. Painting
    // for it then is wasted; the graph catches up when it becomes visible.
    function repaint() { if (root.visible) graph.requestPaint() }
    onHistoryDataChanged: { hoverIndex=-1; repaint() }
    onTintChanged: repaint()
    onWriteTintChanged: repaint()
    onBusyTintChanged: repaint()
    onUsedTintChanged: repaint()
    onGridChanged: repaint()
    onAxisTextChanged: repaint()
    onVisibleChanged: repaint()
    function plotWidth() { return Math.max(1, width-leftAxis-rightAxis) }
    function xFor(ts) { return leftAxis+plotWidth()*(ts-(historyData.now-historyData.seconds))/historyData.seconds }
    Canvas {
        id: graph
        anchors.fill: parent
        onWidthChanged: root.repaint()
        onHeightChanged: root.repaint()
        onPaint: {
            var c=getContext('2d'), w=root.plotWidth(), h=height-26, x0=root.leftAxis
            c.reset();c.clearRect(0,0,width,height)
            c.font='10px "'+root.fontFamily+'"'
            for(var line=0;line<=4;line++){
                var y=8+(h-8)*line/4
                c.strokeStyle=root.grid;c.lineWidth=1;c.beginPath();c.moveTo(x0,y);c.lineTo(x0+w,y);c.stroke()
                c.fillStyle=root.axisText;c.textAlign='right';c.fillText(Model.shortRate(root.ceiling*(1-line/4))+'/s',x0-4,y+3)
                c.textAlign='left';c.fillText(String(100-line*25)+'%',x0+w+4,y+3)
            }
            function yRate(v){return 8+(h-8)*(1-Model.clamp(v,0,root.ceiling)/root.ceiling)}
            function yPct(v){return 8+(h-8)*(1-Model.clamp(v,0,100)/100)}
            var pts=root.points
            function trace(index, style, widthPx, yFn, dashed){
                c.lineWidth=widthPx;c.strokeStyle=style;c.setLineDash(dashed?[3,3]:[])
                c.beginPath();var pen=false
                for(var i=0;i<pts.length;i++){
                    var p=pts[i], v=p[index]
                    if(v===null||v===undefined){pen=false;continue}
                    var x=root.xFor(p[0]), yy=yFn(v)
                    if(!pen || p[0]-pts[i-1][0]>root.historyData.bucket*2.5 || p[7]!==pts[i-1][7]) c.moveTo(x,yy); else c.lineTo(x,yy)
                    pen=true
                }
                c.stroke();c.setLineDash([])
            }
            trace(2,Qt.alpha(root.tint,0.28),1,yRate,false)
            trace(4,Qt.alpha(root.usedTint,0.7),1,yPct,true)
            trace(5,Qt.alpha(root.busyTint,0.85),1,yPct,false)
            trace(3,root.writeTint,1.4,yRate,false)
            trace(1,root.tint,2.2,yRate,false)
            if(pts.length){
                var last=pts[pts.length-1]
                c.fillStyle=root.tint;c.beginPath();c.arc(root.xFor(last[0]),yRate(last[1]||0),3,0,Math.PI*2);c.fill()
            }
            c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',x0,height-3)
            c.textAlign='right';c.fillText('now',x0+w,height-3)
        }
    }
    Rectangle {
        visible: root.hoverPoint !== null
        x: root.hoverPoint ? Math.max(root.leftAxis,Math.min(root.width-root.rightAxis,root.xFor(root.hoverPoint[0]))) : 0
        y: 8; width: 1; height: parent.height-34; color: root.crosshair
    }
    Rectangle {
        visible: root.hoverPoint !== null
        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
        width: hoverText.implicitWidth+20; height: 27; radius: 7; color:root.hoverBackground;border.color:root.hoverBorder
        Text {
            id: hoverText; anchors.centerIn:parent; color:root.hoverForeground;font.family:root.fontFamily;font.pixelSize:11
            text: {
                var p=root.hoverPoint
                if(!p) return ''
                return Qt.formatDateTime(new Date(p[0]*1000),'ddd h:mm AP')+'  ·  R '+Model.rate(p[1])+'  ·  W '+Model.rate(p[3])+'  ·  '+Model.pct(p[4])+' used  ·  '+Model.whole(p[5])+' busy'
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
