import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CpuModel.js" as Model
import "Constraints.js" as Constraints

// CPU section of Pulse — the whole of nixfred.cpu-pulse's dashboard, hosted
// inside the merged panel. Everything below the host bridge is the original
// plugin's own code, so nothing it measured or showed is lost in the merge.
Item {
    id: root

    // ---- host bridge -------------------------------------------------
    // The merged Panel owns the popup, the bar entry and the settings blob.
    // The section reaches those through `host`, and keeps the member names the
    // original code already used, so the ported body needs no rewriting.
    required property var host
    readonly property string prefix: 'cpu'
    readonly property string moduleName: host.moduleName
    readonly property var bar: host.bar
    readonly property color barForeground: host.barForeground
    // ---- transparent bar -------------------------------------------------
    // With the bar transparent there is no slab behind the ink, so the two
    // colours that assume one have to go. The die keeps no fill: a square of
    // the bar's surface colour hangs over the wallpaper in a colour picked for
    // a solid bar. And an inactive reading dims the bar's own ink instead of
    // using `muted`, which was chosen to sit on a slab and turns to mud over a
    // wallpaper while the live state still looks right. The outline and the lit
    // cells carry the chip on their own.
    readonly property bool barTransparent: root.bar ? root.bar.transparent === true : false
    readonly property color barInk: root.bar ? root.bar.barForeground : Color.foreground
    readonly property color barTint: (root.stale && root.barTransparent) ? Util.alpha(root.barInk, 0.55) : root.tint
    // The caption beneath the chip is 7px text, not a stroke: at the chip's
    // dimmed alpha its thin glyphs measure barely above the wallpaper, so it
    // takes the bar's ink whole while the bar is transparent - the same rule
    // the headline directly above it already follows. The chip still dims, and
    // the word OFFLINE is what carries the state.
    readonly property color barCaptionInk: (root.barTransparent && root.stale) ? root.barInk : root.tint
    readonly property bool cardLive: host.opened && host.active === 'overview' && !root.stale && root.setting('animated', true)
    readonly property bool opened: host.opened && host.active === root.prefix
    readonly property var tabs: ['Overview','CPU hogs','Processor lab','About']
    readonly property int lastTab: root.tabs.length-1
    function setting(key, fallback) { return host.setting(root.prefix+'.'+key, fallback) }
    function setSetting(key, value) { host.setSetting(root.prefix+'.'+key, value) }
    function close() { host.close() }
    function open() { host.openSection(root.prefix) }
    width: parent ? parent.width : 0
    property Item dashboard: null
    implicitHeight: dashboard ? dashboard.implicitHeight : 0

    readonly property string stateDir: (Quickshell.env('XDG_STATE_HOME') || Quickshell.env('HOME')+'/.local/state')+'/cpu-pulse'
    readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl('../collectors/cpu_pulse.py')).replace(/^file:\/\//,''))
    property var cpu: ({})
    property string version: ''
    property string palette: ''
    // Every colour in the dashboard resolves from the active Omarchy theme.
    // `ink` is the popup text role; the chrome is that colour at varying
    // strength, which keeps one decision driving the whole surface. Buttons
    // use the shell's own control-state fills, so a theme that tunes those
    // tunes this panel with them.
    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)
    readonly property color rule: Util.alpha(ink, 0.14)
    // The load ramp is data, not decoration, so it only adopts the theme's
    // red/yellow/green when those three stay far enough apart to still read as
    // a scale. Model.rampStops falls back to the built-in ramp otherwise.
    readonly property var rampStops: Model.rampStops(palette)
    readonly property color heat: Model.heatColor(palette, rampStops)
    property var histories: ({})
    property int tab: 0
    property int page: 0
    property int range: 3600
    property bool chooseMode: false
    property string actionStatus: ''
    property real now: Date.now()/1000
    readonly property bool stale: !cpu.ts || now-cpu.ts > 15
    readonly property int mode: Model.clamp(setting('displayMode',0),0,3)
    readonly property color tint: stale ? Color.muted : Model.ramp(cpu.idlePct, rampStops)
    readonly property real pressure: cpu.psi && cpu.psi.some ? cpu.psi.some.avg10 : 0
    readonly property var rows: cpu.hogs || []
    onRowsChanged: page=Math.min(page,Math.max(0,Math.ceil(rows.length/8)-1))
    readonly property var cores: cpu.cores || []
    readonly property var coreLoads: cores.map(function(c){return c.busy})
    readonly property var chart: histories[String(range)] || {points:[],seconds:range,now:now,bucket:15,count:0,peak:0}
    readonly property string health: stale ? 'WAITING FOR TELEMETRY' : cpu.temp >= 90 ? 'RUNNING HOT' : pressure >= 10 ? 'CPU IS CONTENDED' : cpu.busyPct >= 85 ? 'FULLY LOADED' : 'CRUISING'

    function setMode(value) {
        root.setSetting('displayMode', Model.clamp(value,0,3))
    }
    function runAction(action, extra) {
        if(actionProc.running) return
        actionStatus=action==='profile'?'Asking power-profiles-daemon…':'Finding the existing window…'
        actionProc.command=['python3',helper,action].concat(extra||[])
        actionProc.running=true
    }
    // The panel names a link; the helper holds the two URLs. Nothing the
    // snapshot or a window title carries can reach the desktop URL handler.
    function openLink(name) {
        if(actionProc.running) return
        actionStatus='Opening '+name+' in your browser…'
        actionProc.command=['python3',helper,'visit','--link',name]
        actionProc.running=true
    }
    function status() {
        return JSON.stringify({opened:opened,version:version,mode:mode,readout:Model.readout(cpu,mode),tint:String(tint),stale:stale,samples:chart.count || 0,tab:tab,chooseMode:chooseMode,busy:cpu.busyPct,temp:cpu.temp,threads:cpu.threads,hogs:rows.length,profile:cpu.profile,action:actionStatus})
    }
    onOpenedChanged: if(opened) { snapshotFile.reload(); historyFile.reload() }
    FileView {
        id:snapshotFile; path:root.stateDir+'/snapshot.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{var m=JSON.parse(text());if(m.warm)root.cpu=m}catch(e){}}
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
    // The shell parses colors.toml into foreground/background/accent/urgent/
    // muted and stops there, so the green and yellow the ramp needs are read
    // here instead. Theme switches reach Color over IPC rather than through a
    // file watch, so Color changing is the signal to re-read.
    FileView {
        id:paletteFile; path:Quickshell.env('HOME')+'/.local/state/omarchy/current/theme/colors.toml'; printErrors:false
        onLoaded:root.palette=text()
        onLoadFailed:root.palette=''
    }
    Connections {
        target:Color
        function onBackgroundChanged() {paletteFile.reload()}
        function onAccentChanged() {paletteFile.reload()}
    }
    Timer { interval:3000; running:true; repeat:true; onTriggered:{root.now=Date.now()/1000; if(root.stale)snapshotFile.reload()} }
    Process {
        id:actionProc
        stdout:StdioCollector { onStreamFinished:{try{var r=JSON.parse(text);root.actionStatus=r.error || r.message || 'Done';if(!r.error && r.message && r.message.indexOf('Focused ')===0)root.close()}catch(e){root.actionStatus='Action could not complete.'}} }
        onExited:function(code){if(code!==0 && root.actionStatus.indexOf('…')>=0)root.actionStatus='Action could not complete.'}
    }


    // ---- summary surface ----------------------------------------------
    // The merged Overview card and the merged bar row read the section
    // through these five members and the two Components below, so each
    // domain keeps its own readout grammar instead of being flattened into
    // a lowest common denominator.
    readonly property string verdict: root.health
    readonly property string sectionTitle: 'CPU'
    readonly property string sectionBlurb: 'Your processor, in motion.'
    // The bar-readout chooser, rendered by the merged Settings page.
    readonly property int modeCount: 4
    readonly property string modeHint: 'Choose what lives beside the die. One decimal.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   ·   '+Model.readout(root.cpu,index) }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.cpu(root.cpu, root.stale)
    // The worst row that is actually a constraint, skipping the rows that only
    // describe how the machine is set up.
    readonly property var topConstraint: Constraints.leading(root.constraints)
    readonly property real concern: root.topConstraint ? root.topConstraint.severity : 0
    readonly property string constraintLabel: root.topConstraint ? root.topConstraint.label : 'No constraint'
    readonly property string constraintValue: root.topConstraint ? root.topConstraint.value : '—'
    // Sliced once per data change. Slicing inside a Repeater's model binding
    // hands it a new array identity on every evaluation, which destroys and
    // rebuilds every delegate each time.
    readonly property var topConstraints: root.constraints.slice(0, 3)
    // ---- demand-driven process scanning -------------------------------
    // The per-process walk in this domain's collector is essentially its
    // entire cost — 0.29 s every 9 s on an idle machine, against 0.000 s for
    // the readings it sits beside — and the only thing that ever displays it
    // is the tab below. This marker is refreshed while that tab is on screen;
    // the collector skips the walk whenever it is stale, which is nearly
    // always. A resource monitor should not spend a slice of a core building
    // a table nobody has open.
    readonly property bool wantsProcesses: root.opened && root.tab === 1
    FileView { id: wantFile; path: root.stateDir + '/want-processes'; printErrors: false }
    function markProcessesWanted() { wantFile.setText(String(Date.now())) }
    onWantsProcessesChanged: if (root.wantsProcesses) root.markProcessesWanted()
    // Refreshed well inside the collector's 30 s staleness window, so a long
    // look at the table never has it blink out mid-read.
    Timer {
        interval: 10000
        repeat: true
        running: root.wantsProcesses
        triggeredOnStart: true
        onTriggered: root.markProcessesWanted()
    }
    readonly property string headline: root.stale ? '—' : Model.readout(root.cpu, root.mode)
    readonly property string tag: Model.modeTag(root.mode)
    property Component barChip: Component { CpuChip {compact:true;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.barTint;stops:root.rampStops;dieFill:root.barTransparent?'transparent':Color.background;glint:root.barInk;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { CpuChip {width:88;height:88;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.popups.background;glint:root.ink;animate:root.cardLive} }
    property Component cardGraph: Component { CpuHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;heat:root.heat;ink:root.ink;surface:Color.popups.background} }

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
        radius:12;color:root.card;border.color:root.cardEdge
        Column {anchors.fill:parent;anchors.margins:12;spacing:5
            Label{text:label;font.pixelSize:10;font.letterSpacing:1}
            Heading{text:value;font.pixelSize:20}
            Label{text:hint;font.pixelSize:10}
        }
    }

    // The dashboard is the original plugin's whole panel. Building all four
    // of those on every click is what made the merged popup take seconds to
    // appear; tearing them down on close made it take seconds to go. The bar
    // only needs the readings above. This tree is created the first time you
    // open this domain, kept while you stay on it (including through the
    // panel's close fade), and dropped when you leave.
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
                Column {
                    width:parent.width;spacing:14;visible:root.tab===0
                    height:visible?implicitHeight:0
                    Rectangle {
                        width:parent.width;height:170;radius:16;border.color:Qt.alpha(root.tint,0.45)
                        gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.card}}
                        CpuChip {id:heroChip;x:12;y:5;width:160;height:160;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.background;glint:root.ink;animate:root.opened&&root.tab===0&&!root.stale&&root.setting('animated',true)}
                        Column {x:188;y:20;spacing:6
                            Label{text:'PROCESSOR BUSY';font.pixelSize:11;font.letterSpacing:2}
                            Row {spacing:10
                                Text {text:root.stale?'—':(root.cpu.busyPct||0).toFixed(1);color:root.ink;font.pixelSize:52;font.weight:Font.Light}
                                Label{text:'%';font.pixelSize:18;anchors.bottom:parent.bottom;anchors.bottomMargin:10}
                            }
                            Label{text:Model.ghz(root.cpu.freq?root.cpu.freq.avg:null)+' average clock  /  '+(root.cpu.threads||0)+' threads on '+(root.cpu.physical||0)+' cores';color:root.inkDim}
                            Label{text:(root.cpu.model||'Unknown processor')+'  ·  busy = everything except idle and I/O wait';font.pixelSize:10;width:520;elide:Text.ElideRight}
                        }
                        Text {anchors.right:parent.right;anchors.rightMargin:20;anchors.top:parent.top;anchors.topMargin:22;text:Model.temp(root.cpu.temp)+'\npackage';color:Qt.alpha(root.ink,0.5);font.pixelSize:15;horizontalAlignment:Text.AlignRight}
                    }
                    Row {width:parent.width;spacing:10
                        Stat{width:(parent.width-20)/3;height:96;label:'LOAD · 1 MIN';value:Model.load((root.cpu.load||[0])[0]);hint:Model.pct(root.cpu.loadPct)+' of '+(root.cpu.threads||0)+' threads · 5m '+Model.load((root.cpu.load||[0,0])[1])+' · 15m '+Model.load((root.cpu.load||[0,0,0])[2])}
                        Stat{width:(parent.width-20)/3;height:96;label:'CLOCK';value:Model.ghz(root.cpu.freq?root.cpu.freq.avg:null);hint:'Fastest thread '+Model.ghz(root.cpu.freq?root.cpu.freq.peak:null)+' · ceiling '+Model.ghz(root.cpu.freq?root.cpu.freq.max:null)}
                        Stat{width:(parent.width-20)/3;height:96;label:'CPU PRESSURE';value:Model.pct(root.pressure);hint:'Time tasks waited for a CPU · last 10s'}
                    }
                    Rectangle {width:parent.width;height:242;radius:14;color:root.card;border.color:root.cardEdge
                        Column {anchors.fill:parent;anchors.margins:14;spacing:9
                            Row {width:parent.width;spacing:7
                                Heading{text:'CONTINUOUS HISTORY';font.pixelSize:12;width:parent.width-222;anchors.verticalCenter:parent.verticalCenter}
                                Repeater{model:[{t:'1 hour',s:3600},{t:'24 hours',s:86400},{t:'7 days',s:604800}]
                                    Action{required property var modelData;text:modelData.t;selected:root.range===modelData.s;implicitWidth:68;implicitHeight:28;onClicked:root.range=modelData.s}
                                }
                            }
                            CpuHistoryGraph{width:parent.width;height:139;historyData:root.chart;tint:root.tint;heat:root.heat;ink:root.ink;surface:Color.popups.background}
                            Row{spacing:14
                                Label{text:'━ CPU busy';color:root.tint;font.pixelSize:10}
                                Label{text:'━ Package °C';color:root.heat;font.pixelSize:10}
                                Label{text:'Peak '+Model.pct(root.chart.peak)+'  ·  '+(root.chart.count||0)+' samples';font.pixelSize:10}
                            }
                            Label{text:(root.chart.count||0)<2?'History is starting. Samples accumulate every 15 seconds.':'Recording while closed · 7-day retention · hover to inspect · faint line = busy peaks';font.pixelSize:10}
                        }
                    }
                    Rectangle {width:parent.width;height:coreColumn.implicitHeight+28;radius:14;color:root.card;border.color:root.cardEdge
                        Column{id:coreColumn;anchors.fill:parent;anchors.margins:14;spacing:9
                            Row{width:parent.width
                                Heading{text:'EVERY THREAD';font.pixelSize:12;width:parent.width/2}
                                Label{text:root.cores.filter(function(c){return c.busy>=50}).length+' of '+root.cores.length+' above half load';width:parent.width/2;horizontalAlignment:Text.AlignRight;color:Color.accent}
                            }
                            Grid{id:threadGrid;width:parent.width;columns:Math.max(1,Math.min(Math.max(6,Math.floor((coreColumn.width+8)/96)),root.cores.length));columnSpacing:8;rowSpacing:8
                                Repeater{model:root.cores
                                    Column{required property var modelData;width:(coreColumn.width-8*(threadGrid.columns-1))/threadGrid.columns;spacing:4
                                        Row{width:parent.width
                                            Label{text:'T'+modelData.id;font.pixelSize:10;color:Color.accent;width:parent.width/2}
                                            Label{text:Model.pct(modelData.busy);font.pixelSize:10;width:parent.width/2;horizontalAlignment:Text.AlignRight;color:root.ink}
                                        }
                                        Rectangle{width:parent.width;height:5;radius:3;color:Util.alpha(root.ink,0.13)
                                            Rectangle{width:parent.width*Model.clamp(modelData.busy/100,0,1);height:parent.height;radius:3;color:Model.ramp(100-modelData.busy, root.rampStops);Behavior on width{NumberAnimation{duration:800}}}
                                        }
                                        Label{text:Model.ghz(modelData.freq)+(modelData.temp!==null&&modelData.temp!==undefined?' · '+Model.temp(modelData.temp):'');font.pixelSize:9}
                                    }
                                }
                            }
                            Label{text:'Sibling threads share a physical core; the clock is the average delivered frequency, idle time included.';font.pixelSize:10}
                        }
                    }
                }
                Column {
                    width:parent.width;spacing:10;visible:root.tab===1;height:visible?implicitHeight:0
                    Row{width:parent.width
                        Heading{text:'TOP CPU HOGS';width:parent.width-210;font.pixelSize:13}
                        Label{text:'Ranked by CPU time · refresh 9s';font.pixelSize:10}
                    }
                    Label{text:'Click a row to visit its app or attached session. Background processes show details.';font.pixelSize:11}
                    Repeater {
                        model:root.rows.slice(root.page*8,root.page*8+8)
                        Rectangle {
                            id:procRow
                            required property var modelData
                            required property int index
                            width:mainColumn.width;height:65;radius:10
                            color:hogMouse.containsMouse?Style.hoverFill:root.card;border.color:hogMouse.containsMouse?root.tint:root.cardEdge
                            Rectangle{anchors.left:parent.left;anchors.bottom:parent.bottom;anchors.leftMargin:12;anchors.bottomMargin:5;width:(parent.width-24)*Model.clamp(procRow.modelData.cpu/(100*(root.cpu.threads||1)),0,1);height:2;radius:1;color:root.tint}
                            Label{x:12;y:22;text:String(root.page*8+procRow.index+1).padStart(2,'0');font.pixelSize:12;color:root.tint}
                            Column{x:44;y:10;spacing:5;width:parent.width-222
                                Heading{text:procRow.modelData.name+'  ·  '+procRow.modelData.pid;font.pixelSize:13;width:parent.width;elide:Text.ElideRight}
                                Label{text:procRow.modelData.target.address?(procRow.modelData.target.host.kind==='herdr'?'Herdr '+procRow.modelData.target.host.pane+' · ':procRow.modelData.target.host.kind==='tmux'?'tmux '+procRow.modelData.target.host.pane+' · ':'')+procRow.modelData.target.title:'Background process · no attached window';width:parent.width;elide:Text.ElideRight;font.pixelSize:10}
                            }
                            Column{anchors.right:parent.right;anchors.rightMargin:35;y:10;spacing:5
                                Heading{text:Model.pct(procRow.modelData.cpu);font.pixelSize:15;anchors.right:parent.right}
                                Label{text:(procRow.modelData.sampled?'':'lifetime avg · ')+procRow.modelData.threads+' threads';font.pixelSize:10;anchors.right:parent.right}
                            }
                            Label{anchors.right:parent.right;anchors.rightMargin:13;y:22;text:procRow.modelData.target.address?'↗':'ⓘ';color:root.tint;font.pixelSize:16}
                            MouseArea{id:hogMouse;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
                                onClicked: {if(procRow.modelData.target.address)root.runAction('focus',[String(procRow.modelData.pid),String(procRow.modelData.start)]);else root.actionStatus=procRow.modelData.name+' · PID '+procRow.modelData.pid+' · '+Model.pct(procRow.modelData.cpu/(root.cpu.threads||1))+' of the whole processor · nice '+procRow.modelData.nice+' · state '+procRow.modelData.state+'. No existing window to focus.'}
                            }
                        }
                    }
                    Row{spacing:10
                        Action{text:'← Previous';opacity:root.page>0?1:0.4;onClicked:root.page=Math.max(0,root.page-1)}
                        Label{text:(root.page+1)+' / '+Math.max(1,Math.ceil(root.rows.length/8));anchors.verticalCenter:parent.verticalCenter}
                        Action{text:'Next →';opacity:(root.page+1)*8<root.rows.length?1:0.4;onClicked:root.page=Math.min(Math.max(0,Math.ceil(root.rows.length/8)-1),root.page+1)}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Percentages are of one thread, like top: a process can exceed 100%. The bar under each row is its share of the whole processor. Browser subprocesses lead to their browser window.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===2;height:visible?implicitHeight:0
                    Heading{text:'UNDER THE HOOD';font.pixelSize:13}
                    Grid{width:parent.width;columns:3;spacing:10
                        Repeater{model:[
                            {l:'USER',v:Model.pct((root.cpu.breakdown||{}).user),h:'Time in application code'},
                            {l:'SYSTEM',v:Model.pct((root.cpu.breakdown||{}).system),h:'Time inside the kernel'},
                            {l:'NICE',v:Model.pct((root.cpu.breakdown||{}).nice),h:'Low-priority background work'},
                            {l:'I/O WAIT',v:Model.pct((root.cpu.breakdown||{}).iowait),h:'Idle while storage catches up'},
                            {l:'IRQ + SOFTIRQ',v:Model.pct(((root.cpu.breakdown||{}).irq||0)+((root.cpu.breakdown||{}).softirq||0)),h:'Interrupt handling · network, timers'},
                            {l:'STEAL',v:Model.pct((root.cpu.breakdown||{}).steal),h:'Taken by a hypervisor · 0 on bare metal'},
                            {l:'CONTEXT SWITCHES',v:Model.rate((root.cpu.rates||{}).ctxt),h:'Task changes per second'},
                            {l:'INTERRUPTS',v:Model.rate((root.cpu.rates||{}).intr),h:'Hardware and timer interrupts'},
                            {l:'NEW PROCESSES',v:Model.rate((root.cpu.rates||{}).processes),h:'Forks and clones per second'},
                            {l:'RUNNABLE NOW',v:String(root.cpu.running||0),h:'Tasks running or queued this instant'},
                            {l:'BLOCKED ON I/O',v:String(root.cpu.blocked||0),h:'Tasks in uninterruptible sleep'},
                            {l:'ALL TASKS STALLED',v:Model.pct(root.cpu.psi&&root.cpu.psi.full?root.cpu.psi.full.avg10:0),h:'Full CPU pressure · last 10s'}
                        ]
                            Stat{required property var modelData;width:(mainColumn.width-20)/3;height:91;label:modelData.l;value:modelData.v;hint:modelData.h}
                        }
                    }
                    Column{width:parent.width;spacing:7
                        Label{width:parent.width;text:(root.cpu.freq?root.cpu.freq.driver+' · '+root.cpu.freq.governor+' governor'+(root.cpu.freq.epp?' · '+root.cpu.freq.epp+' preference':'')+' · turbo '+(root.cpu.freq.turbo===true?'on':root.cpu.freq.turbo===false?'off':'unknown')+' · base '+Model.ghz(root.cpu.freq.base):'Frequency driver unavailable')+'  ·  throttled '+((root.cpu.throttle||{}).package||0)+'× since boot'+(root.cpu.watts!==null&&root.cpu.watts!==undefined?'  ·  '+root.cpu.watts.toFixed(1)+' W package':'');color:Util.alpha(Color.accent,0.78);font.pixelSize:11;wrapMode:Text.WordWrap}
                        Label{width:parent.width;text:(root.cpu.sensors||[]).map(function(s){return s.label+' '+Model.temp(s.temp)}).join('  ·  ') || 'No CPU temperature sensors exposed';color:Util.alpha(Color.accent,0.78);font.pixelSize:11;wrapMode:Text.WordWrap}
                    }
                    Rectangle{width:parent.width;height:152;radius:12;color:Util.alpha(Color.accent,0.09);border.color:Util.alpha(Color.accent,0.38)
                        Column{anchors.fill:parent;anchors.margins:14;spacing:9
                            Heading{text:'POWER PROFILE';font.pixelSize:12}
                            Label{width:parent.width;wrapMode:Text.WordWrap;text:root.cpu.profile?'power-profiles-daemon shapes clocks and thermals for the whole machine. Changes apply immediately and are fully reversible here. Performance costs battery and heat; power-saver costs responsiveness.':'power-profiles-daemon is not running, so profiles cannot be switched from here.';font.pixelSize:11;color:root.inkDim}
                            Row{spacing:8
                                Repeater{model:['power-saver','balanced','performance']
                                    Action{required property string modelData;text:actionProc.running&&root.actionStatus.indexOf('Asking')===0?'Working…':modelData;accent:Color.accent;selected:root.cpu.profile===modelData;opacity:root.cpu.profile?1:0.4;onClicked:if(root.cpu.profile)root.runAction('profile',[modelData])}
                                }
                            }
                        }
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Breakdown fields sum to 100% of processor time. No process termination, renicing, affinity pinning, frequency locking or privileged tuning is exposed.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===3;height:visible?implicitHeight:0
                    Rectangle {
                        width:parent.width;height:132;radius:16;border.color:Qt.alpha(root.tint,0.45)
                        gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.card}}
                        CpuChip {x:14;y:6;width:120;height:120;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.background;glint:root.ink;animate:false}
                        Column {x:150;y:24;spacing:6
                            Heading{text:'CPU PULSE';font.pixelSize:22;font.letterSpacing:3}
                            Label{text:'Your processor, in motion.';font.pixelSize:11}
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
                    Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'github.com/nixfred/omacpu  ·  nixfred.com'}
                    Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'History stays on this machine in a private state directory. CPU Pulse reads unprivileged kernel counters only; it never terminates a process, renices, pins affinity or locks a frequency.'}
                }
                Rectangle{width:parent.width;height:1;color:root.rule}
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10;color:root.stale?Color.urgent:root.inkDim;text:root.actionStatus || (root.stale?'Telemetry is offline. Check the cpu-pulse user service.': 'LIVE · updated '+Qt.formatTime(new Date(root.cpu.ts*1000),'h:mm:ss AP')+'  ·  History stays on this machine  ·  Esc closes')}
        }
    }
}
