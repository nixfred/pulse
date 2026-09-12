import QtQuick
import "NetModel.js" as Model

// A glowing network chip. The body carries a radio (signal arcs) or a wired
// jack (pins with a link light); packets run along the chip pins faster as
// traffic rises. Aura, rings and pins match RAM Pulse and CPU Pulse so the
// three chips read as siblings on the bar.
Item {
    id: root
    property string kind: 'offline'   // 'wifi' | 'ethernet' | 'offline'
    property real level: 0            // 0–1 signal quality or link health
    property real activity: 0         // 0–1 normalised traffic, drives packet speed
    property bool animate: true
    property bool compact: false
    // Ramp stops the panel supplies from the active theme; the built-in ramp
    // stands in when the chip is used on its own.
    property var stops: null
    property color tint: Model.ramp(level * 100, stops)
    // The chip body sits on whatever surface holds it, so it reads as cut out
    // of the bar or the card rather than pasted onto them.
    property color body: '#0b141b'
    property real phase: 0
    property real shownLevel: level
    implicitWidth: compact ? 28 : 160
    implicitHeight: compact ? 25 : 160
    // One phase revolution every 5.8s, advanced by the repaint tick itself.
    readonly property real phaseStep: tick.interval / 5800
    // Every repaint is coalesced onto this single 10Hz tick, and nothing is
    // painted while the chip is off screen. An infinite NumberAnimation on
    // phase drove the canvas at display refresh rate instead, and the
    // shownLevel and tint Behaviors kept doing the same through every
    // transition even when animation was switched off.
    Timer {
        id: tick
        interval: 100; repeat: true
        running: root.animate && root.visible
        onTriggered: { root.phase = (root.phase + root.phaseStep) % 1; canvas.requestPaint() }
    }
    function repaint() { if (root.visible) canvas.requestPaint() }
    onTintChanged: repaint()
    onShownLevelChanged: repaint()
    onKindChanged: repaint()
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
            var lvl=Model.clamp(root.shownLevel,0,1), act=Model.clamp(root.activity,0,1)
            var aura=c.createRadialGradient(cx,cy,body*0.1,cx,cy,size*0.5)
            aura.addColorStop(0,Qt.alpha(root.tint,0.30+0.25*lvl)); aura.addColorStop(0.6,Qt.alpha(root.tint,0.20+0.07*Math.sin(t))); aura.addColorStop(1,'transparent')
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
            // Glow as a few widening, fading strokes, not shadowBlur. The blur is
            // rasterised on the GUI thread and cost 30-70 ms per paint at card size,
            // at ten paints a second per chip, which is what made the panel hesitate
            // as it opened. These strokes cost about a millisecond.
            var haloBase=c.lineWidth
            c.save(); c.strokeStyle=root.tint
            for(var halo=(root.compact?2:4); halo>0; halo--){ c.globalAlpha=0.09; c.lineWidth=haloBase+halo*(root.compact?1.2:2.4); c.strokeRect(x,y,body,body) }
            c.restore()
            c.strokeRect(x,y,body,body)
            c.save();c.beginPath();c.rect(x+2,y+2,body-4,body-4);c.clip()
            c.strokeStyle=Qt.alpha(root.tint,0.18);c.lineWidth=0.8
            for(var row=1;row<4;row++){ c.beginPath();c.moveTo(x,y+body*row/4);c.lineTo(x+body,y+body*row/4);c.stroke() }
            if (root.kind === 'wifi') {
                // Signal arcs fan out from the antenna dot; lit arcs follow quality, the top arc pulses.
                var ox=cx, oy=y+body*0.82, arcs=4
                c.fillStyle=root.tint;c.beginPath();c.arc(ox,oy,body*0.055,0,Math.PI*2);c.fill()
                for(var a=1;a<=arcs;a++){
                    var lit=lvl*arcs>=a-0.5, pulse=(a===Math.min(arcs,Math.max(1,Math.ceil(lvl*arcs))))?0.65+0.35*Math.sin(t*2):1
                    c.beginPath();c.strokeStyle=Qt.alpha(root.tint,lit?0.9*pulse:0.16);c.lineWidth=(root.compact?1.3:3)*(lit?1:0.7)
                    c.arc(ox,oy,body*0.17*a,Math.PI*1.25,Math.PI*1.75);c.stroke()
                }
            } else if (root.kind === 'ethernet') {
                // A wired jack: eight contacts with a running link light.
                var jw=body*0.62, jh=body*0.5, jx=cx-jw/2, jy=cy-jh/2+body*0.04
                c.strokeStyle=Qt.alpha(root.tint,0.85);c.lineWidth=root.compact?1:2
                c.beginPath();c.moveTo(jx,jy+jh);c.lineTo(jx,jy+jh*0.35);c.lineTo(jx+jw*0.18,jy+jh*0.35);c.lineTo(jx+jw*0.18,jy);c.lineTo(jx+jw*0.82,jy);c.lineTo(jx+jw*0.82,jy+jh*0.35);c.lineTo(jx+jw,jy+jh*0.35);c.lineTo(jx+jw,jy+jh);c.closePath();c.stroke()
                for(var pin=0;pin<8;pin++){
                    var px=jx+jw*(0.16+pin*0.68/7), on=Math.floor(t/(Math.PI*2)*8*(1+act*3))%8===pin
                    c.strokeStyle=Qt.alpha(root.tint,on&&root.animate?1:0.35+0.45*lvl);c.lineWidth=root.compact?1:2
                    c.beginPath();c.moveTo(px,jy+jh*0.62);c.lineTo(px,jy+jh*0.92);c.stroke()
                }
            } else {
                // Offline: a broken link ring.
                c.strokeStyle=Qt.alpha(root.tint,0.7);c.lineWidth=root.compact?1.2:2.5;c.setLineDash([body*0.08,body*0.08])
                c.beginPath();c.arc(cx,cy,body*0.28,0,Math.PI*2);c.stroke();c.setLineDash([])
                c.beginPath();c.moveTo(cx-body*0.2,cy+body*0.2);c.lineTo(cx+body*0.2,cy-body*0.2);c.stroke()
            }
            c.restore()
            c.strokeStyle=root.tint;c.lineWidth=root.compact?1:2
            for(var p=0;p<4;p++) {
                var q=body*(p+1)/5, len=body*0.17
                c.beginPath();c.moveTo(x+q,y-len);c.lineTo(x+q,y);c.moveTo(x+q,y+body);c.lineTo(x+q,y+body+len)
                c.moveTo(x-len,y+q);c.lineTo(x,y+q);c.moveTo(x+body,y+q);c.lineTo(x+body+len,y+q);c.stroke()
                if(!root.compact && root.kind !== 'offline'){
                    // Packets: inbound run down the top pins, outbound run out the right pins. Speed follows traffic.
                    var progress=((root.phase*(1+act*4))+p/4)%1
                    c.fillStyle=Qt.alpha(root.tint,1-progress*0.5)
                    c.beginPath();c.arc(x+q,y-len-body*0.3+progress*body*0.3,1.7,0,Math.PI*2);c.fill()
                    c.beginPath();c.arc(x+body+len+progress*body*0.3,y+q,1.7,0,Math.PI*2);c.fill()
                }
            }
        }
    }
}
