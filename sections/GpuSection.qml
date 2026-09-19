import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GpuModel.js" as Model
import "Constraints.js" as Constraints

// GPU section of Pulse.
//
// The other four sections are ports of plugins that existed on their own first,
// generated out of their upstream panels by tools/merge-from-upstream.py. There
// is no upstream GPU Pulse, so this one is written directly against the same
// contracts: the same host bridge, the same summary surface the bar and the
// Overview and Constraints pages read, the same four-tab shape, the same lazy
// dashboard. It is deliberately absent from the generator's SPEC, which would
// otherwise try to find an upstream plugin to transplant and fail.
Item {
    id: root

    // ---- host bridge -------------------------------------------------
    required property var host
    readonly property string prefix: 'gpu'
    readonly property string moduleName: host.moduleName
    readonly property var bar: host.bar
    readonly property color barForeground: host.barForeground
    // ---- transparent bar ----------------------------------------------
    // Same rule the other four follow: with the bar transparent there is no
    // slab behind the ink, so the chip drops its fill and an inactive reading
    // dims the bar's own ink rather than using a colour picked to sit on a
    // surface that is not there.
    readonly property bool barTransparent: root.bar ? root.bar.transparent === true : false
    readonly property color barInk: root.bar ? root.bar.barForeground : Color.foreground
    readonly property color barTint: (root.stale && root.barTransparent) ? Util.alpha(root.barInk, 0.55) : root.tint
    readonly property color barCaptionInk: (root.barTransparent && root.stale) ? root.barInk : root.tint
    readonly property bool cardLive: host.opened && host.active === 'overview' && !root.stale && root.setting('animated', true)
    readonly property bool opened: host.opened && host.active === root.prefix
    readonly property var tabs: ['Overview','GPU hogs','Graphics lab','About']
    readonly property int lastTab: root.tabs.length-1
    function setting(key, fallback) { return host.setting(root.prefix+'.'+key, fallback) }
    function setSetting(key, value) { host.setSetting(root.prefix+'.'+key, value) }
    function close() { host.close() }
    function open() { host.openSection(root.prefix) }
    width: parent ? parent.width : 0
    property Item dashboard: null
    implicitHeight: dashboard ? dashboard.implicitHeight : 0

    readonly property string stateDir: (Quickshell.env('XDG_STATE_HOME') || Quickshell.env('HOME')+'/.local/state')+'/gpu-pulse'
    readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl('../collectors/gpu_pulse.py')).replace(/^file:\/\//,''))
    property var gpu: ({})
    property string version: ''
    property string palette: ''
    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)
    readonly property color rule: Util.alpha(ink, 0.14)
    readonly property var rampStops: Model.rampStops(palette)
    readonly property color heat: Model.heatColor(palette, rampStops)
    // VRAM keeps a colour of its own everywhere it appears, because it is a
    // different question from "is it working" and the two must not be read as
    // one number.
    readonly property color memTint: root.stale ? Color.muted : Model.ramp(root.gpu.memUsedPct, rampStops)
    // The chip's memory band stays on the ramp: it is a gauge, and a card that
    // is nearly full should go red. A trace on a chart is not a gauge, and
    // tinting it by its own value put the VRAM line and the temperature line in
    // the same warm register at exactly the moment they both mattered. The
    // graph gets a stable colour instead.
    readonly property color memTrace: root.stale ? Color.muted : Color.accent
    property var histories: ({})
    property int tab: 0
    property int page: 0
    property int range: 3600
    property bool chooseMode: false
    property string actionStatus: ''
    property real now: Date.now()/1000
    readonly property bool stale: !gpu.ts || now-gpu.ts > 15
    readonly property int mode: Model.clamp(setting('displayMode',0),0,3)
    readonly property color tint: stale ? Color.muted : Model.ramp(gpu.busyPct, rampStops)
    readonly property var cards: gpu.cards || []
    readonly property var rows: gpu.hogs || []
    onRowsChanged: page=Math.min(page,Math.max(0,Math.ceil(rows.length/8)-1))
    readonly property var chart: histories[String(range)] || {points:[],seconds:range,now:now,bucket:15,count:0,peak:0}
    readonly property string health: Model.health(gpu, stale)
    // Lab tiles spread to whatever width the panel has, the same rule the
    // storage lab follows, so a wide screen means fewer rows rather than a
    // page that runs off the bottom.
    // A process holds memory on the card it runs on, which is not necessarily
    // the one the headline readings come from. Dividing every hog by the primary
    // card's total misreported every process on a second GPU.
    function cardTotal(id) {
        for (var i = 0; i < root.cards.length; i++)
            if (root.cards[i].id === id && root.cards[i].memTotal) return root.cards[i].memTotal
        return root.gpu.memTotal || 0
    }
    readonly property int labColumns: Math.max(4, Math.floor((root.width + 10) / 200))

    function setMode(value) {
        root.setSetting('displayMode', Model.clamp(value,0,3))
    }
    function runAction(action, extra) {
        if(actionProc.running) return
        actionStatus='Finding the existing window…'
        actionProc.command=['python3',helper,action].concat(extra||[])
        actionProc.running=true
    }
    function openLink(name) {
        if(actionProc.running) return
        actionStatus='Opening '+name+' in your browser…'
        actionProc.command=['python3',helper,'visit','--link',name]
        actionProc.running=true
    }
    function status() {
        return JSON.stringify({opened:opened,version:version,mode:mode,readout:Model.readout(gpu,mode),tint:String(tint),stale:stale,samples:chart.count || 0,tab:tab,chooseMode:chooseMode,present:!!gpu.present,vendor:gpu.vendor,busy:gpu.busyPct,vram:gpu.memUsedPct,temp:gpu.tempC,power:gpu.powerW,cards:cards.length,hogs:rows.length,throttle:(gpu.throttleActive||[]).length,action:actionStatus})
    }
    onOpenedChanged: if(opened) { snapshotFile.reload(); historyFile.reload() }
    FileView {
        id:snapshotFile; path:root.stateDir+'/snapshot.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{var m=JSON.parse(text());if(m.warm)root.gpu=m}catch(e){}}
    }
    FileView {
        id:historyFile; path:root.stateDir+'/history.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{root.histories=JSON.parse(text())}catch(e){}}
    }
    FileView {
        id:manifestFile; path:String(Qt.resolvedUrl('../manifest.json')).replace(/^file:\/\//,''); printErrors:false
        onLoaded:{try{root.version=String(JSON.parse(text()).version||'')}catch(e){}}
    }
    FileView {
        id:paletteFile
        path:(Quickshell.env('XDG_CONFIG_HOME') || Quickshell.env('HOME')+'/.config')+'/omarchy/current/theme/colors.toml'
        watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{root.palette=text()}
    }
    Connections {
        target:Color
        function onBackgroundChanged() {paletteFile.reload()}
        function onAccentChanged() {paletteFile.reload()}
    }
    Timer { interval:1000; repeat:true; running:true; onTriggered:root.now=Date.now()/1000 }
    Process {
        id:actionProc
        stdout:StdioCollector{onStreamFinished:{try{var r=JSON.parse(text());root.actionStatus=r.error||r.message||''}catch(e){root.actionStatus=''}}}
    }

    // ---- summary surface ----------------------------------------------
    // The merged Overview card, the Constraints page and the bar row read the
    // section through these members, so a fifth domain needs nothing special
    // anywhere else to appear in all three.
    readonly property string verdict: root.health
    readonly property string sectionTitle: 'GPU'
    readonly property string sectionBlurb: 'Your graphics, in motion.'
    readonly property int modeCount: 4
    readonly property string modeHint: 'Choose what lives beside the die. One decimal.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   ·   '+Model.readout(root.gpu,index) }
    readonly property var constraints: Constraints.gpu(root.gpu, root.stale)
    readonly property var topConstraint: Constraints.leading(root.constraints)
    readonly property real concern: root.topConstraint ? root.topConstraint.severity : 0
    readonly property string constraintLabel: root.topConstraint ? root.topConstraint.label : 'No constraint'
    readonly property string constraintValue: root.topConstraint ? root.topConstraint.value : '—'
    readonly property var topConstraints: root.constraints.slice(0, 3)

    // ---- demand-driven process scanning -------------------------------
    // Reading which processes hold video memory is cheaper than the CPU
    // domain's /proc walk, but it still has exactly one consumer: the tab
    // below. The collector skips it whenever this marker is stale.
    readonly property bool wantsProcesses: root.opened && root.tab === 1
    FileView { id: wantFile; path: root.stateDir + '/want-processes'; printErrors: false }
    function markProcessesWanted() { wantFile.setText(String(Date.now())) }
    onWantsProcessesChanged: if (root.wantsProcesses) root.markProcessesWanted()
    Timer {
        interval: 10000
        repeat: true
        running: root.wantsProcesses
        triggeredOnStart: true
        onTriggered: root.markProcessesWanted()
    }

    readonly property string headline: root.stale ? '—' : Model.readout(root.gpu, root.mode)
    readonly property string tag: Model.modeTag(root.mode)
    property Component barChip: Component { GpuChip {compact:true;busy:root.gpu.busyPct || 0;vram:root.gpu.memUsedPct || 0;tint:root.barTint;memTint:root.memTint;body:root.barTransparent?'transparent':Color.background;glint:root.barInk;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { GpuChip {width:88;height:88;busy:root.gpu.busyPct || 0;vram:root.gpu.memUsedPct || 0;tint:root.tint;memTint:root.memTint;body:Color.popups.background;glint:root.ink;animate:root.cardLive} }
    property Component cardGraph: Component { GpuHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;heat:root.heat;memTint:root.memTrace;ink:root.ink;surface:Color.popups.background} }

    component Label: Text {
        color:root.inkDim;font.pixelSize:12;textFormat:Text.PlainText
    }
    component Heading: Text {
        color:root.ink;font.pixelSize:15;font.bold:true;textFormat:Text.PlainText
    }
    component Action: Rectangle {
        id:act
        property string text:''
        property bool selected:false
        property color accent:root.tint
        signal clicked()
        implicitWidth:caption.implicitWidth+26;implicitHeight:34
        radius:9;color:act.selected?Qt.alpha(accent,Style.selectedFillAlpha):area.containsMouse?Style.hoverFill:Style.normalFill
        border.color:act.selected?accent:area.containsMouse?Style.hoverBorderColor:Style.normalBorderColor
        Behavior on color {ColorAnimation{duration:120}}
        Text{id:caption;anchors.centerIn:parent;text:act.text;color:act.selected?root.ink:root.inkDim;font.pixelSize:12;font.bold:act.selected;textFormat:Text.PlainText}
        MouseArea{id:area;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor;onClicked:act.clicked()}
    }
    component Stat: Rectangle {
        property string label:''
        property string value:''
        property string hint:''
        property int valueSize:20
        radius:12;color:root.card;border.color:root.cardEdge
        Column {anchors.fill:parent;anchors.margins:12;spacing:5
            Label{text:label;font.pixelSize:10;font.letterSpacing:1}
            Heading{text:value;font.pixelSize:valueSize}
            Label{text:hint;font.pixelSize:10;width:parent.width;elide:Text.ElideRight}
        }
    }

    // The dashboard is built the first time this domain is opened and kept
    // while you stay on it, the same as the other four.
    Repeater {
        model: (host.active === root.prefix && (host.opened || root.dashboard)) ? 1 : 0
        onItemAdded: function (index, item) { root.dashboard = item }
        onItemRemoved: function (index, item) { if (root.dashboard === item) root.dashboard = null }
        Column {
            id: mainColumn
            width: root.width
            spacing: 14
            Row {
                spacing: 8
                Repeater {
                    model: root.tabs
                    Action {
                        required property int index
                        required property string modelData
                        text: modelData
                        selected: root.tab === index
                        onClicked: root.tab = index
                    }
                }
            }

            // ---- Overview ------------------------------------------------
            Column {
                width:parent.width;spacing:10;visible:root.tab===0
                height:visible?implicitHeight:0
                Rectangle {
                    width:parent.width;height:170;radius:16;border.color:Qt.alpha(root.tint,0.45)
                    gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.card}}
                    GpuChip {x:12;y:5;width:160;height:160;busy:root.gpu.busyPct || 0;vram:root.gpu.memUsedPct || 0;tint:root.tint;memTint:root.memTint;body:Color.popups.background;glint:root.ink;animate:root.opened && !root.stale && root.setting('animated',true)}
                    Column {x:188;y:20;spacing:6
                        Label{text:root.gpu.present===false?'NO GPU DETECTED':'GRAPHICS BUSY';font.pixelSize:11;font.letterSpacing:2}
                        Row {spacing:10
                            Heading{text:root.stale?'—':Model.pct(root.gpu.busyPct);font.pixelSize:44}
                            Label{text:root.stale?'':'busy';font.pixelSize:13;anchors.bottom:parent.bottom;anchors.bottomMargin:10}
                        }
                        Label{width:root.width-220;elide:Text.ElideRight;text:(root.gpu.name||'—')+(root.gpu.count>1?'  ·  +'+(root.gpu.count-1)+' more':'');font.pixelSize:12}
                        Label{width:root.width-220;elide:Text.ElideRight;text:root.gpu.driver?'Driver '+root.gpu.driver+'  ·  '+Model.vendorName(root.gpu.vendor):Model.vendorName(root.gpu.vendor);font.pixelSize:10}
                    }
                    Column {anchors.right:parent.right;anchors.rightMargin:18;y:20;spacing:4;width:190
                        Heading{text:root.health;font.pixelSize:13;horizontalAlignment:Text.AlignRight;width:parent.width;wrapMode:Text.WordWrap}
                        Label{text:root.stale?'':Model.temp(root.gpu.tempC);font.pixelSize:20;horizontalAlignment:Text.AlignRight;width:parent.width;color:root.heat}
                    }
                }
                Row {width:parent.width;spacing:10
                    Stat{width:(parent.width-30)/4;height:90;label:'VIDEO MEMORY';value:Model.pct(root.gpu.memUsedPct);hint:Model.size(root.gpu.memUsed)+' of '+Model.size(root.gpu.memTotal)}
                    Stat{width:(parent.width-30)/4;height:90;label:'POWER';value:Model.watts(root.gpu.powerW);hint:root.gpu.powerLimitW&&root.gpu.powerPct!==null&&root.gpu.powerPct!==undefined?Math.round(root.gpu.powerPct)+'% of a '+Math.round(root.gpu.powerLimitW)+' W limit':root.gpu.powerLimitW?'limit '+Math.round(root.gpu.powerLimitW)+' W':'no limit reported'}
                    Stat{width:(parent.width-30)/4;height:90;label:'CLOCK';value:Model.mhz(root.gpu.clockSmMhz);hint:root.gpu.clockSmMaxMhz&&root.gpu.clockPct!==null&&root.gpu.clockPct!==undefined?Math.round(root.gpu.clockPct)+'% of '+Model.mhz(root.gpu.clockSmMaxMhz):root.gpu.clockSmMaxMhz?'peak '+Model.mhz(root.gpu.clockSmMaxMhz):'peak unknown'}
                    Stat{width:(parent.width-30)/4;height:90;label:'STATE';value:Model.pstate(root.gpu.pstate);hint:(root.gpu.throttleActive||[]).length?'held back · '+(root.gpu.throttleActive||[]).length+' reason(s)':'nothing holding it back'}
                }
                Rectangle {width:parent.width;height:214;radius:14;color:root.card;border.color:root.cardEdge
                    Column {anchors.fill:parent;anchors.margins:14;spacing:9
                        Row {width:parent.width;spacing:7
                            Heading{text:'HISTORY';font.pixelSize:13;width:parent.width-260;anchors.verticalCenter:parent.verticalCenter}
                            Repeater{model:[{t:'1 hour',s:3600},{t:'24 hours',s:86400},{t:'7 days',s:604800}]
                                Action{required property var modelData;text:modelData.t;selected:root.range===modelData.s;implicitHeight:28;onClicked:root.range=modelData.s}
                            }
                        }
                        GpuHistoryGraph{width:parent.width;height:111;historyData:root.chart;tint:root.tint;heat:root.heat;memTint:root.memTrace;ink:root.ink;surface:Color.popups.background}
                        Row{spacing:14
                            Label{text:'● busy';color:root.tint;font.pixelSize:10}
                            Label{text:'● VRAM';color:root.memTrace;font.pixelSize:10}
                            Label{text:'● temperature';color:root.heat;font.pixelSize:10}
                            Label{text:root.chart.count+' samples  ·  peak '+Model.pct(root.chart.peak);font.pixelSize:10}
                        }
                        Label{width:parent.width;font.pixelSize:10;text:'Recorded every 15s and kept for 7 days · hover to inspect · faint line = busy peaks'}
                    }
                }
                Rectangle {width:parent.width;height:cardColumn.implicitHeight+28;radius:14;color:root.card;border.color:root.cardEdge;visible:root.cards.length>1
                    Column{id:cardColumn;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;anchors.margins:14;spacing:9
                        Item{width:parent.width;height:20
                            Heading{text:'EVERY GPU';font.pixelSize:13}
                            Label{anchors.right:parent.right;text:root.cards.length+' adapters · the discrete one leads';font.pixelSize:10}
                        }
                        Repeater{model:root.cards
                            Item{
                                id:gcard
                                required property var modelData
                                width:cardColumn.width;height:26
                                Label{width:parent.width*0.46;elide:Text.ElideRight;font.pixelSize:11;color:gcard.modelData.discrete?root.ink:root.inkDim
                                    text:(gcard.modelData.discrete?'◆ ':'◇ ')+gcard.modelData.name}
                                Label{anchors.right:parent.right;font.pixelSize:11
                                    text:(gcard.modelData.busyPct===null||gcard.modelData.busyPct===undefined?'—':Model.pct(gcard.modelData.busyPct))+' busy'
                                        +(gcard.modelData.memUsedPct!==null&&gcard.modelData.memUsedPct!==undefined?'  ·  '+Model.pct(gcard.modelData.memUsedPct)+' VRAM':'')
                                        +(gcard.modelData.tempC?'  ·  '+Model.temp(gcard.modelData.tempC):'')}
                                Rectangle{y:20;width:parent.width;height:4;radius:2;color:root.cardEdge
                                    Rectangle{width:parent.width*Model.clamp(gcard.modelData.busyPct||0,0,100)/100;height:parent.height;radius:2;color:gcard.modelData.discrete?root.tint:root.inkDim
                                        Behavior on width{NumberAnimation{duration:220}}}
                                }
                            }
                        }
                    }
                }
            }

            // ---- GPU hogs ------------------------------------------------
            Column {
                width:parent.width;spacing:6;visible:root.tab===1;height:visible?implicitHeight:0
                Row{width:parent.width;spacing:8
                    Heading{text:'WHAT IS HOLDING THE CARD';width:parent.width-210;font.pixelSize:13;anchors.verticalCenter:parent.verticalCenter}
                    Label{text:'Ranked by video memory · refresh 9s';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                }
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'Video memory is not shared or swapped: whatever is listed here is memory the next job cannot have. Click a row to visit its window or attached session.'}
                Repeater {
                    model:root.rows.slice(root.page*8,root.page*8+8)
                    Rectangle {
                        id:procRow
                        required property var modelData
                        required property int index
                        width:mainColumn.width;height:65;radius:10
                        color:hogMouse.containsMouse?Style.hoverFill:root.card;border.color:hogMouse.containsMouse?root.tint:root.cardEdge
                        Rectangle{anchors.left:parent.left;anchors.bottom:parent.bottom;anchors.leftMargin:12;anchors.bottomMargin:5;height:2;radius:1;color:root.memTint
                            width:(parent.width-24)*Model.clamp(procRow.modelData.memBytes/(root.cardTotal(procRow.modelData.card)||1),0,1)}
                        Label{x:12;y:22;text:String(root.page*8+procRow.index+1).padStart(2,'0');font.pixelSize:12;color:root.tint}
                        Column{x:44;y:10;spacing:5;width:parent.width-240
                            Heading{text:procRow.modelData.name+'  ·  '+procRow.modelData.pid;font.pixelSize:13;width:parent.width;elide:Text.ElideRight}
                            Label{text:procRow.modelData.kind==='graphics'?'Drawing to the screen':'Compute work · '+(procRow.modelData.mine?'yours':'another user');width:parent.width;elide:Text.ElideRight;font.pixelSize:10}
                        }
                        Column{anchors.right:parent.right;anchors.rightMargin:35;y:10;spacing:5
                            Heading{text:Model.size(procRow.modelData.memBytes);font.pixelSize:15;anchors.right:parent.right}
                            Label{text:(procRow.modelData.smPct===null||procRow.modelData.smPct===undefined?'no per-process load':procRow.modelData.smPct+'% of the card')+'  ·  '+Model.pct(procRow.modelData.memBytes/(root.cardTotal(procRow.modelData.card)||1)*100);font.pixelSize:10;anchors.right:parent.right}
                        }
                        Label{anchors.right:parent.right;anchors.rightMargin:13;y:22;text:procRow.modelData.mine?'↗':'ⓘ';color:root.tint;font.pixelSize:16}
                        MouseArea{id:hogMouse;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
                            onClicked: {if(procRow.modelData.mine)root.runAction('focus',[String(procRow.modelData.pid),String(procRow.modelData.start)]);else root.actionStatus=procRow.modelData.name+' · PID '+procRow.modelData.pid+' · '+Model.size(procRow.modelData.memBytes)+' of video memory. It belongs to another user, so there is no window here to focus.'}
                        }
                    }
                }
                Label{width:parent.width;visible:!root.rows.length;wrapMode:Text.WordWrap;font.pixelSize:11
                    text:root.stale?'Telemetry is offline.':root.gpu.present===false?'No GPU on this machine to hold.':'Nothing is holding video memory right now. NVIDIA reports this list; Intel and AMD cards do not expose per-process memory the same way.'}
                Row{spacing:10;visible:root.rows.length>8
                    Action{text:'← Previous';opacity:root.page>0?1:0.4;onClicked:root.page=Math.max(0,root.page-1)}
                    Label{text:(root.page+1)+' / '+Math.max(1,Math.ceil(root.rows.length/8));anchors.verticalCenter:parent.verticalCenter}
                    Action{text:'Next →';opacity:(root.page+1)*8<root.rows.length?1:0.4;onClicked:root.page=Math.min(Math.max(0,Math.ceil(root.rows.length/8)-1),root.page+1)}
                }
            }

            // ---- Graphics lab --------------------------------------------
            Column {
                width:parent.width;spacing:10;visible:root.tab===2;height:visible?implicitHeight:0
                Heading{text:'THE WHOLE CARD';font.pixelSize:13}
                Grid{width:parent.width;columns:root.labColumns;spacing:10
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'ADAPTER';value:Model.vendorName(root.gpu.vendor)||'—';hint:root.gpu.name||'no adapter'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'DRIVER';value:root.gpu.driver||'—';hint:root.gpu.vendor==='nvidia'?'through NVML':'through sysfs'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'BUSY';value:Model.pct(root.gpu.busyPct);hint:'share of the last sample'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'VIDEO MEMORY';value:Model.pct(root.gpu.memUsedPct);hint:Model.size(root.gpu.memUsed)+' of '+Model.size(root.gpu.memTotal)}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'TEMPERATURE';value:Model.temp(root.gpu.tempC);hint:'silicon'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'POWER';value:Model.watts(root.gpu.powerW);hint:root.gpu.powerLimitW?'limit '+Math.round(root.gpu.powerLimitW)+' W':'limit not reported'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'CORE CLOCK';value:Model.mhz(root.gpu.clockSmMhz);hint:'peak '+Model.mhz(root.gpu.clockSmMaxMhz)}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'FAN';value:root.gpu.fanPct===null||root.gpu.fanPct===undefined?'—':Model.whole(root.gpu.fanPct);hint:root.gpu.fanPct===null||root.gpu.fanPct===undefined?'not reported on this card':'of full speed'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'POWER STATE';value:Model.pstate(root.gpu.pstate);hint:'P0 is flat out'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'PCIE LINK';value:root.cards.length&&root.cards[0].pcieWidth&&root.cards[0].pcieGen?'gen '+root.cards[0].pcieGen+' x'+root.cards[0].pcieWidth:'—';hint:'drops when idle to save power'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'ENCODER';value:root.gpu.encoderPct===null||root.gpu.encoderPct===undefined?'—':Model.whole(root.gpu.encoderPct);hint:'video encode engine'}
                    Stat{width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:'ADAPTERS';value:String(root.gpu.count||0);hint:root.cards.length>1?'discrete leads the readings':'one adapter'}
                }
                Rectangle {width:parent.width;height:throttleColumn.implicitHeight+26;radius:14;color:root.card;border.color:root.cardEdge
                    Column{id:throttleColumn;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;anchors.margins:13;spacing:7
                        Heading{text:'WHAT IS LIMITING IT';font.pixelSize:13}
                        Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11
                            text:(root.gpu.throttleActive||[]).length
                                ? 'Right now: '+(root.gpu.throttleActive||[]).map(Model.throttleName).join(', ')+'.'
                                : (root.gpu.throttleReasons||[]).length
                                  ? 'Nothing is holding the card back. The driver reports only '+(root.gpu.throttleReasons||[]).map(Model.throttleName).join(', ')+', which describes how it is set up rather than a limit being hit.'
                                  : 'Nothing is holding the card back.'}
                        Row{spacing:16
                            Label{font.pixelSize:11;text:'Power limited: '+Model.perMinute((root.gpu.throttleRate||{}).power)}
                            Label{font.pixelSize:11;text:'Thermally limited: '+Model.perMinute((root.gpu.throttleRate||{}).thermal)}
                        }
                        Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10
                            text:'These are rates, not totals. The driver counts these since boot, and a laptop card sits at its board power limit essentially always, so the running total says "limited for days" on a machine that is perfectly healthy. Only a reason the driver reports right now counts as a constraint.'}
                    }
                }
            }

            // ---- About ---------------------------------------------------
            Column {
                width:parent.width;spacing:12;visible:root.tab===3;height:visible?implicitHeight:0
                Rectangle {
                    width:parent.width;height:132;radius:16;border.color:Qt.alpha(root.tint,0.45)
                    gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.card}}
                    GpuChip {x:14;y:6;width:120;height:120;busy:root.gpu.busyPct || 0;vram:root.gpu.memUsedPct || 0;tint:root.tint;memTint:root.memTint;body:Color.background;glint:root.ink;animate:false}
                    Column {x:150;y:24;spacing:6
                        Heading{text:'GPU PULSE';font.pixelSize:22;font.letterSpacing:3}
                        Label{text:'Your graphics, in motion.';font.pixelSize:11}
                        Row {spacing:8
                            Rectangle {
                                height:24;width:versionText.implicitWidth+18;radius:12
                                color:Qt.alpha(root.tint,0.16);border.color:Qt.alpha(root.tint,0.5)
                                Text{id:versionText;anchors.centerIn:parent;text:root.version?'v'+root.version:'version unavailable';color:root.ink;font.pixelSize:11;font.bold:true;textFormat:Text.PlainText}
                            }
                            Label{text:'MIT · Fred Nix';font.pixelSize:11;anchors.verticalCenter:parent.verticalCenter}
                        }
                    }
                }
                Row {spacing:8
                    Action{text:'Source code on GitHub →';onClicked:root.openLink('repo')}
                    Action{text:'nixfred.com →';onClicked:root.openLink('author')}
                }
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'github.com/nixfred/pulse  ·  nixfred.com'}
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'The only domain here with no plugin of its own before Pulse. NVIDIA cards are read through the driver’s own library rather than by running nvidia-smi: a full sample costs 0.017 ms against 46 ms to start that program, which is the difference between a monitor you can leave running and one that charges you for looking. Intel and AMD cards are read from the kernel’s sysfs counters.'}
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'History stays on this machine in a private state directory. GPU Pulse reads unprivileged driver and kernel counters only; it never sets a clock, a power limit, a fan curve or a persistence mode, and it never stops a process.'}
            }
            Rectangle{width:parent.width;height:1;color:root.rule}
            Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10;color:root.stale?Color.urgent:root.inkDim
                text:Model.recorderStatus(root.actionStatus,root.stale,root.gpu.present,root.gpu.reason,Qt.formatTime(new Date(root.gpu.ts*1000),'h:mm:ss AP'))}
        }
    }
}
