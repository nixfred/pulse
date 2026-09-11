import QtQuick
import "DiskModel.js" as Model

// A glowing storage die. The body is a map of flash blocks that light up as
// the filesystem fills; a read/write beam sweeps the map faster as traffic
// rises, reads run out of the top pins and writes run in through the bottom
// ones. The aura, orbit rings and pins match RAM Pulse, CPU Pulse and Net
// Pulse so the four chips read as siblings on the bar.
Item {
    id: root
    property real free: 50          // 0–100, percentage of the filesystem still free
    property real activity: 0       // 0–1 normalised traffic, drives beam and ring speed
    property real reading: 0        // 0–1 normalised read throughput
    property real writing: 0        // 0–1 normalised write throughput
    property bool animate: true
    property bool compact: false
    property color tint: Model.ramp(free)
    // The chip's own body. The panel passes the theme's popup background so the
    // silicon reads as a cut-out of the panel rather than a fixed dark square.
    property color body: '#0b141b'
    property color glint: '#ffffff'
    property real phase: 0
    readonly property real used: 1 - Model.clamp(free, 0, 100) / 100
    implicitWidth: compact ? 28 : 160
    implicitHeight: compact ? 25 : 160
    // One phase revolution every 5.8s, advanced by the repaint tick itself.
    readonly property real phaseStep: tick.interval / 5800
    // Every repaint is coalesced onto this single 10Hz tick, and nothing is
    // painted while the chip is off screen. An infinite NumberAnimation on
    // phase drove the canvas at display refresh rate instead, and the level
    // and tint Behaviors kept doing the same through every transition even
    // when animation was switched off.
    Timer {
        id: tick
        interval: 100; repeat: true
        running: root.animate && root.visible
        onTriggered: { root.phase = (root.phase + root.phaseStep) % 1; canvas.requestPaint() }
    }
    function repaint() { if (root.visible) canvas.requestPaint() }
    onTintChanged: repaint()
    onBodyChanged: repaint()
    onGlintChanged: repaint()
    onUsedChanged: repaint()
    onActivityChanged: repaint()
    onAnimateChanged: repaint()
    onVisibleChanged: repaint()
    Canvas {
        id: canvas
        anchors.fill: parent
        onWidthChanged: root.repaint()
        onHeightChanged: root.repaint()
        onPaint: {
            var c = getContext('2d'), w = width, h = height
            c.reset(); c.clearRect(0,0,w,h)
            var cx=w/2, cy=h/2, size=Math.min(w,h), body=size*(root.compact?0.58:0.47)
            if (size <= 0 || body <= 0) return
            var x=cx-body/2, y=cy-body/2, t=root.phase*Math.PI*2
            var act=Model.clamp(root.activity,0,1), rd=Model.clamp(root.reading,0,1), wr=Model.clamp(root.writing,0,1)
            var aura=c.createRadialGradient(cx,cy,body*0.1,cx,cy,size*0.5)
            aura.addColorStop(0,Qt.alpha(root.tint,0.30+0.25*act)); aura.addColorStop(0.6,Qt.alpha(root.tint,0.20+0.07*Math.sin(t))); aura.addColorStop(1,'transparent')
            c.fillStyle=aura; c.fillRect(0,0,w,h)
            if (!root.compact) {
                for(var ring=0;ring<3;ring++) {
                    c.beginPath(); c.strokeStyle=Qt.alpha(root.tint,0.11+ring*0.04); c.lineWidth=1
                    c.arc(cx,cy,body*(0.78+ring*0.12),0,Math.PI*2); c.stroke()
                    c.beginPath(); c.strokeStyle=Qt.alpha(root.tint,0.65); c.lineWidth=2
                    var ang=t*(1+act*2)*(ring%2===0?1:-1)+ring*2
                    c.arc(cx,cy,body*(0.78+ring*0.12),ang,ang+0.42);c.stroke()
                }
            }
            c.fillStyle=root.body; c.strokeStyle=root.tint; c.lineWidth=root.compact?1.2:2
            c.fillRect(x,y,body,body)
            c.shadowColor=root.tint; c.shadowBlur=root.compact?5:12
            c.strokeRect(x,y,body,body); c.shadowBlur=0
            c.save();c.beginPath();c.rect(x+2,y+2,body-4,body-4);c.clip()
            // Block map. Blocks fill from the bottom as the filesystem fills;
            // the one at the waterline is lit in proportion, so a slow fill
            // still moves. Each lit block carries a fixed grain of its own so
            // the map reads as storage rather than a flat bar.
            var cols=root.compact?4:8, rows=root.compact?4:6, n=cols*rows
            var gap=root.compact?1:2, inner=body-4, bw=(inner-gap*(cols+1))/cols, bh=(inner-gap*(rows+1))/rows
            var lit=root.used*n
            for(var i=0;i<n;i++){
                var col=i%cols, row=rows-1-Math.floor(i/cols)
                var px=x+2+gap+col*(bw+gap), py=y+2+gap+row*(bh+gap)
                var fill=Model.clamp(lit-i,0,1)
                var grain=((i*7919)%13)/13*0.18
                c.fillStyle=Qt.alpha(root.tint,0.10+fill*(0.62+grain))
                c.fillRect(px,py,bw,bh)
            }
            // Read/write beam: sweeps the map at a pace that quickens with traffic.
            var sweep=((root.phase*(1+act*3))%1)*(body+16)-8
            var beam=c.createLinearGradient(0,y+sweep-8,0,y+sweep+8)
            beam.addColorStop(0,'transparent'); beam.addColorStop(0.5,Qt.alpha(root.glint,(root.compact?0.22:0.28)+0.2*act)); beam.addColorStop(1,'transparent')
            c.fillStyle=beam; c.fillRect(x,y+sweep-8,body,16)
            c.restore()
            c.strokeStyle=root.tint;c.lineWidth=root.compact?1:2
            for(var pin=0;pin<4;pin++) {
                var p=body*(pin+1)/5, len=body*0.17
                c.beginPath();c.moveTo(x+p,y-len);c.lineTo(x+p,y);c.moveTo(x+p,y+body);c.lineTo(x+p,y+body+len)
                c.moveTo(x-len,y+p);c.lineTo(x,y+p);c.moveTo(x+body,y+p);c.lineTo(x+body+len,y+p);c.stroke()
                if(!root.compact){
                    // Reads leave through the top pins, writes arrive through
                    // the bottom ones. Each runs at its own throughput.
                    var out=((root.phase*(1+rd*4))+pin/4)%1
                    c.fillStyle=Qt.alpha(root.tint,1-out*0.5)
                    c.beginPath();c.arc(x+p,y-len-out*body*0.3,1.7,0,Math.PI*2);c.fill()
                    var inn=((root.phase*(1+wr*4))+pin/4)%1
                    c.fillStyle=Qt.alpha(root.tint,0.5+inn*0.5)
                    c.beginPath();c.arc(x+p,y+body+len+body*0.3-inn*body*0.3,1.7,0,Math.PI*2);c.fill()
                }
            }
        }
    }
}
