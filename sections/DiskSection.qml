import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "DiskModel.js" as Model
import "Constraints.js" as Constraints

// Disk section of Pulse — the whole of nixfred.disk-pulse's dashboard, hosted
// inside the merged panel. Everything below the host bridge is the original
// plugin's own code, so nothing it measured or showed is lost in the merge.
Item {
    id: root

    // ---- host bridge -------------------------------------------------
    // The merged Panel owns the popup, the bar entry and the settings blob.
    // The section reaches those through `host`, and keeps the member names the
    // original code already used, so the ported body needs no rewriting.
    required property var host
    readonly property string prefix: 'disk'
    // Storage-lab tiles spread to the width they are given, so a wide panel
    // shows the same tiles in fewer rows instead of pushing past the screen.
    readonly property int labColumns: Math.max(4, Math.floor((root.width + 10) / 200))
    readonly property string moduleName: host.moduleName
    readonly property var bar: host.bar
    readonly property color barForeground: host.barForeground
    readonly property bool cardLive: host.opened && host.active === 'overview' && !root.stale && root.setting('animated', true)
    readonly property bool opened: host.opened && host.active === root.prefix
    readonly property var tabs: ['Overview','Disk hogs','Storage lab','About']
    readonly property int lastTab: root.tabs.length-1
    function setting(key, fallback) { return host.setting(root.prefix+'.'+key, fallback) }
    function setSetting(key, value) { host.setSetting(root.prefix+'.'+key, value) }
    function close() { host.close() }
    function open() { host.openSection(root.prefix) }
    width: parent ? parent.width : 0
    implicitHeight: mainColumn.implicitHeight

    readonly property string stateDir: Model.stateDir(Quickshell.env('HOME'), Quickshell.env('XDG_STATE_HOME'))
    // Theme surface. Every colour the panel paints derives from the active
    // Omarchy theme: the popup roles for chrome, and the theme's own red,
    // yellow and green for the headroom ramp. Card fills and strokes are the
    // foreground laid over the popup background at low alpha, so they follow a
    // light theme as readily as a dark one instead of assuming either.
    readonly property color themeText: Color.popups.text
    readonly property color themeBg: Color.popups.background
    readonly property color themeAccent: Color.accent
    readonly property color themeMuted: Color.muted
    readonly property color themeUrgent: Color.urgent
    readonly property color themeSoft: Qt.alpha(themeText,0.78)
    readonly property color surfaceIdle: Qt.tint(themeBg,Qt.alpha(themeText,0.03))
    readonly property color surface: Qt.tint(themeBg,Qt.alpha(themeText,0.05))
    readonly property color surfaceHover: Qt.tint(themeBg,Qt.alpha(themeText,0.11))
    readonly property color stroke: Qt.tint(themeBg,Qt.alpha(themeText,0.18))
    readonly property color strokeStrong: Qt.tint(themeBg,Qt.alpha(themeText,0.34))
    readonly property string themeFont: bar ? bar.fontFamily : Style.font.family
    // The three ramp stops, read from the theme's own palette file.
    property var rampPalette: Model.RAMP_FALLBACK
    readonly property color rampWarn: rampPalette.mid
    readonly property color rampGood: rampPalette.high
    readonly property string helper: String(Qt.resolvedUrl('../collectors/disk_pulse.py')).replace(/^file:\/\//,'')
    // Identity for the About line. The manifest is the single source of truth
    // for all three, so bumping a version or moving the repo is one edit there.
    // The constants are the fallback for when the registry is not reachable.
    readonly property var pluginManifest: {
        var reg = bar && bar.shell ? bar.shell.pluginRegistry : null
        return reg && reg.installedPlugins ? (reg.installedPlugins[root.moduleName] || null) : null
    }
    // Some shell builds hand back an empty registry entry for a plugin that
    // is plainly running, so the manifest beside this file is the second
    // source: still the manifest, never a version written into the QML.
    property var fileManifest: ({})
    readonly property string pluginVersion: pluginManifest && pluginManifest.version ? String(pluginManifest.version) : fileManifest.version ? String(fileManifest.version) : ''
    readonly property string repoUrl: pluginManifest && pluginManifest.repository ? String(pluginManifest.repository) : fileManifest.repository ? String(fileManifest.repository) : 'https://github.com/nixfred/disk.pulse'
    readonly property string homeUrl: pluginManifest && pluginManifest.homepage ? String(pluginManifest.homepage) : fileManifest.homepage ? String(fileManifest.homepage) : 'https://nixfred.com'
    property var disk: ({})
    property var histories: ({})
    property int tab: 0
    property int page: 0
    property int range: 3600
    property bool chooseMode: false
    property string actionStatus: ''
    property real now: Date.now()/1000
    readonly property bool stale: !disk.ts || now-disk.ts > 15
    readonly property int mode: Model.clamp(setting('displayMode',0),0,5)
    readonly property string mountpoint: String(setting('mountpoint','/') || '/')
    readonly property bool showReadout: setting('showReadout',true) !== false
    // The filesystem the chip follows and the drive under it.
    readonly property var primary: Model.primaryOf(disk, mountpoint)
    readonly property var drive: Model.driveOf(disk, primary)
    readonly property var hero: Model.heroAmount(primary ? primary.free : 0)
    // Capacity that has not been read is unknown, not zero: the chip goes to
    // the theme's muted colour with an empty map rather than a full red one.
    readonly property bool capacityKnown: primary !== null && primary.responsive !== false && Model.has(primary.freePct)
    readonly property real chipFree: capacityKnown ? primary.freePct : 100
    readonly property color tint: stale || !capacityKnown ? themeMuted : Model.ramp(primary.freePct,rampPalette)
    property int fsPage: 0
    readonly property int fsPerPage: 5
    readonly property real pressure: disk.psi && disk.psi.some ? disk.psi.some.avg10 : 0
    readonly property var rates: disk.rates || {}
    readonly property var rows: disk.hogs || []
    // Telemetry can shorten the list under a reader who is already paging.
    onRowsChanged: page=Math.min(page,Math.max(0,Math.ceil(rows.length/8)-1))
    readonly property var filesystems: disk.filesystems || []
    // A box with a dozen mounts must not push the overview off a 1080p
    // screen, so the card shows five at a time and pages in its header.
    onFilesystemsChanged: fsPage=Math.min(fsPage,Math.max(0,Math.ceil(filesystems.length/fsPerPage)-1))
    readonly property var fsListing: filesystems.slice(fsPage*fsPerPage,fsPage*fsPerPage+fsPerPage)
    readonly property int fsPages: Math.max(1,Math.ceil(filesystems.length/fsPerPage))
    readonly property var disks: disk.disks || []
    readonly property var chart: histories[String(range)] || {points:[],seconds:range,now:now,bucket:15,count:0,peakRead:0,peakWrite:0}
    // Traffic is normalised against the busiest quarter-minute of the last
    // hour, never below 50 MB/s, so a quiet drive does not race and a fast
    // one does not saturate the animation on its first burst.
    readonly property real activityScale: Math.max(5e7,(histories['3600']||{}).peakRead||0,(histories['3600']||{}).peakWrite||0)
    readonly property real activity: stale ? 0 : Model.clamp((Model.num(rates.read)+Model.num(rates.write))/activityScale,0,1)
    readonly property real reading: stale ? 0 : Model.clamp(Model.num(rates.read)/activityScale,0,1)
    readonly property real writing: stale ? 0 : Model.clamp(Model.num(rates.write)/activityScale,0,1)
    readonly property string health: Model.healthLabel(disk,primary,drive,stale)
    readonly property real hogPeak: rows.reduce(function(m,r){return Math.max(m,Model.num(r.readRate)+Model.num(r.writeRate))},0)
    readonly property var pool: primary && primary.pool && disk.btrfs ? disk.btrfs[primary.pool] : null

    function setMode(value) {
        root.setSetting('displayMode', Model.clamp(value,0,5))
    }
    function setMountpoint(value) {
        root.setSetting('mountpoint', String(value||'/'))
    }
    function runAction(action, row) {
        if(actionProc.running) return
        actionStatus=action==='flush'?'Writing pending data to disk…':'Finding the existing window…'
        actionProc.command=['python3',helper,action].concat(row?[String(row.pid),String(row.start)]:[])
        actionProc.running=true
    }
    // The panel closes first, so the page is never opened behind a popup the
    // same click dismissed. xdg-open is detached: a cold browser start must not
    // block the shell's event loop.
    function openUrl(url) {
        if(!url) return
        root.close()
        Quickshell.execDetached(['xdg-open',url])
    }
    // A pool mounted many times names its first two other mounts and counts
    // the rest, so the row stays one line at any number of subvolumes.
    function alsoList(also) {
        var list=also||[]
        if(list.length<=2) return list.join(', ')
        return list.slice(0,2).join(', ')+' +'+(list.length-2)+' more'
    }
    function fsBadges(fs) {
        var out=[]
        if(fs.encrypted) out.push('LUKS')
        if(fs.compress) out.push(fs.compress==='yes'?'compressed':fs.compress)
        if(fs.remote) out.push('remote')
        if(fs.readonly) out.push('read-only')
        return out.join(' · ')
    }
    // The cards on the lab tab. Built here rather than inline so a drive with
    // no SMART (a USB stick, a virtual disk) still lays out cleanly with the
    // cells it cannot fill reading as dashes.
    function driveStats(d) {
        var s=d.smart||{}, r=d.rates||{}
        var health=s.kind==='nvme'?(s.warnings&&s.warnings.length?s.warnings.join(', '):'OK'):s.kind==='ata'?(s.failing?'FAILING':'OK'):'—'
        return [
            {l:'TEMPERATURE',v:Model.temp(d.temp),h:Model.has(d.tempMax)?'warns at '+Model.temp(d.tempMax)+(Model.has(d.tempCrit)?' · critical '+Model.temp(d.tempCrit):''):'no drive sensor exposed'},
            {l:'SMART HEALTH',v:health,h:s.kind==='nvme'?'NVMe critical warning flags':s.kind==='ata'?'overall assessment via udisks':(s.reason||'udisks reports no SMART')},
            {l:'DRIVE WEAR',v:s.kind==='nvme'&&Model.has(s.percentUsed)?Model.whole(s.percentUsed):s.kind==='ata'&&Model.has(s.badSectors)?String(s.badSectors)+' bad sectors':'—',h:s.kind==='nvme'?'of rated endurance used':s.kind==='ata'?'reallocated or pending':'not reported'},
            {l:'POWERED ON',v:Model.hours(s.powerOnHours),h:Model.has(s.powerCycles)?String(s.powerCycles)+' power cycles':'lifetime'},
            {l:'WRITTEN · LIFETIME',v:Model.has(s.totalWritten)?Model.dec(s.totalWritten):'—',h:Model.has(s.totalRead)?'read '+Model.dec(s.totalRead):'host writes to the drive'},
            {l:'SPARE BLOCKS',v:Model.has(s.spare)?Model.whole(s.spare):'—',h:Model.has(s.spareThreshold)?'warns below '+Model.whole(s.spareThreshold):'reserved for wear levelling'},
            {l:'UNSAFE SHUTDOWNS',v:Model.has(s.unsafeShutdowns)?String(s.unsafeShutdowns):'—',h:'power lost before flush'},
            {l:'MEDIA ERRORS',v:Model.has(s.mediaErrors)?String(s.mediaErrors):'—',h:Model.has(s.errorLogEntries)?String(s.errorLogEntries)+' error-log entries':'unrecovered data errors'},
            {l:'IN FLIGHT',v:(d.inflight?d.inflight[0]:0)+' r · '+(d.inflight?d.inflight[1]:0)+' w',h:d.scheduler+' scheduler · depth '+d.nrRequests},
            {l:'LATENCY',v:Model.ms(r.awaitRead).replace(' ms','')+' · '+Model.ms(r.awaitWrite),h:'read · write, per request'},
            {l:'REQUESTS',v:Model.count(r.readIops)+' · '+Model.perSec(r.writeIops),h:'read · write IOPS'},
            {l:'QUEUE DEPTH',v:(Model.num(r.queue)).toFixed(2),h:'average requests waiting'}
        ]
    }
    function poolStats(p) {
        var sp=p.spaces||{}, data=sp.data||{}, meta=sp.metadata||{}, mixed=sp.mixed, e=p.errors||{}, c=p.commits||{}
        // A pool made with mixed block groups keeps data and metadata in one
        // space; it has no separate data or metadata figures to show.
        var head=mixed?[
            {l:'DATA + METADATA',v:Model.size(mixed.used),h:'of '+Model.size(mixed.total)+' allocated · mixed chunks'},
            {l:'MIXED PROFILE',v:mixed.profile||'single',h:'data and metadata share block groups'}
        ]:[
            {l:'DATA',v:Model.size(data.used),h:'of '+Model.size(data.total)+' allocated · '+(data.profile||'single')},
            {l:'METADATA',v:Model.size(meta.used),h:'of '+Model.size(meta.total)+(meta.profile==='dup'?' · DUP, ×2 on disk':' · '+(meta.profile||'single'))}
        ]
        return head.concat([
            {l:'UNALLOCATED',v:Model.size(p.unallocated),h:'raw space no chunk has claimed'},
            {l:'GLOBAL RESERVE',v:Model.size(p.globalReserve?p.globalReserve.size:0),h:'so metadata can always commit'},
            {l:'DEVICE ERRORS',v:String(p.errorTotal||0),h:'r '+(e.read_errs||0)+' · w '+(e.write_errs||0)+' · flush '+(e.flush_errs||0)+' · corrupt '+(e.corruption_errs||0)},
            {l:'LAST COMMIT',v:Model.ms(c.last_commit_ms),h:'slowest '+Model.ms(c.max_commit_ms)+' · '+Model.count(c.commits)+' commits'},
            // discard_bytes_saved counts extents reused before a discard was
            // due, which is work the drive was spared, not bytes trimmed.
            {l:'DISCARD SAVED',v:Model.size(p.discardSaved),h:'reused before a discard was due'},
            {l:'COMPRESSION',v:root.primary&&root.primary.compress?root.primary.compress:'off',h:(p.features||[]).indexOf('compress_zstd')>=0?'zstd in use on this pool':'mount option'}
        ])
    }
    // Dirty and writeback pages are the kernel's side of storage; the trim
    // timer is the drive's housekeeping. Both belong beside the pool.
    function kernelStats() {
        var t=root.disk.trim||{}
        var trim=!t.timer?{v:'—',h:'fstrim.timer not found'}
            :typeof t.last==='number'?{v:Model.ago(Math.max(0,root.now-t.last))+' ago',h:(typeof t.next==='number'?'next in '+Model.ago(Math.max(0,t.next-root.now)):'timer '+t.timer)+(t.result?' · '+t.result:'')}
            :{v:t.last?String(t.last):'never',h:'timer '+t.timer+(t.result?' · '+t.result:'')}
        return [
            {l:'DIRTY PAGES',v:Model.size(root.disk.dirty),h:'changed data waiting for disk'},
            {l:'WRITEBACK',v:Model.size(root.disk.writeback),h:'data currently being written'},
            {l:'ALL TASKS STALLED',v:Model.pct(root.disk.psi&&root.disk.psi.full?root.disk.psi.full.avg10:0),h:'full I/O pressure · last 10s'},
            {l:'LAST TRIM',v:trim.v,h:trim.h}
        ]
    }
    function status() {
        return JSON.stringify({opened:opened,version:pluginVersion,mode:mode,mountpoint:mountpoint,readout:Model.readout(disk,mode,mountpoint),tint:String(tint),stale:stale,samples:chart.count || 0,tab:tab,chooseMode:chooseMode,free:primary?primary.free:null,total:primary?primary.total:null,freePct:primary?primary.freePct:null,read:rates.read,write:rates.write,busy:drive&&drive.rates?drive.rates.util:null,temp:drive?drive.temp:null,filesystems:filesystems.length,disks:disks.length,hogs:rows.length,action:actionStatus})
    }
    onOpenedChanged: if(opened) { snapshotFile.reload(); historyFile.reload() }
    FileView {
        id:snapshotFile; path:root.stateDir+'/snapshot.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{var m=JSON.parse(text());if(m.ts>0)root.disk=m}catch(e){}}
    }
    FileView {
        id:historyFile; path:root.stateDir+'/history.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{root.histories=JSON.parse(text())}catch(e){}}
    }
    FileView {
        id:manifestFile; path:String(Qt.resolvedUrl('../manifest.json')).replace(/^file:\/\//,''); printErrors:false
        onLoaded:{try{var m=JSON.parse(text());if(m&&typeof m==='object')root.fileManifest=m}catch(e){}}
    }
    FileView {
        // The theme's own palette, for the three ramp stops the shell does not
        // expose. watchChanges covers a theme edited in place.
        id:themePalette
        path:Quickshell.env('HOME')+'/.local/state/omarchy/current/theme/colors.toml'
        watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:root.rampPalette=Model.themeRamp(text())
    }
    // A runtime theme switch does not touch colors.toml in a way the watcher
    // can see: the shell loads it once at startup and has the new palette
    // pushed to Color over IPC instead. So re-read the file whenever the
    // shell's own colours move, which is exactly when that push lands.
    readonly property string themeSignature: String(Color.background)+String(Color.foreground)+String(Color.accent)+String(Color.urgent)
    onThemeSignatureChanged: themePalette.reload()
    Timer { interval:3000; running:true; repeat:true; onTriggered:{root.now=Date.now()/1000; if(root.stale)snapshotFile.reload()} }
    Process {
        id:actionProc
        stdout:StdioCollector { onStreamFinished:{try{var r=JSON.parse(text);root.actionStatus=r.error || r.message || 'Done';if(!r.error && r.message && r.message.indexOf('Focused ')===0)root.close()}catch(e){root.actionStatus='Action could not complete.'}} }
        onExited:function(code){if(code!==0 && root.actionStatus.indexOf('…')>=0)root.actionStatus='Action could not complete.'}
    }


    // ---- summary surface ----------------------------------------------
    readonly property string verdict: root.health
    readonly property string sectionTitle: 'Disk'
    readonly property string sectionBlurb: 'Your storage, in motion.'
    // The bar-readout chooser, rendered by the merged Settings page.
    readonly property int modeCount: 6
    readonly property string modeHint: 'Choose what lives beside the chip. One decimal.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   ·   '+Model.readout(root.disk,index,root.mountpoint)+(index===4?'  '+Model.modeTag(root.disk,4):'') }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.disk(root.disk, root.mountpoint, root.primary, root.drive, root.stale)
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
    readonly property string headline: root.stale ? '—' : Model.readout(root.disk, root.mode, root.mountpoint)
    readonly property string tag: Model.modeTag(root.disk, root.mode)
    property Component barChip: Component { DiskChip {compact:true;body:root.themeBg;glint:root.barForeground;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { DiskChip {width:88;height:88;body:Color.popups.background;glint:root.themeText;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:root.cardLive} }
    property Component cardGraph: Component { DiskHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;writeTint:root.themeAccent;busyTint:root.rampWarn;usedTint:root.themeText;grid:root.stroke;axisText:root.themeMuted;crosshair:root.strokeStrong;hoverBackground:root.surfaceHover;hoverBorder:root.stroke;hoverForeground:root.themeText;fontFamily:root.themeFont} }

    component Label: Text {
        color:root.themeMuted;font.pixelSize:12;font.family:root.themeFont;textFormat:Text.PlainText
    }
    component Heading: Text {
        color:root.themeText;font.pixelSize:15;font.bold:true;font.family:root.themeFont;textFormat:Text.PlainText
    }
    component Link: Text {
        id:linkText
        property string url:''
        color:linkArea.containsMouse?root.themeText:root.themeMuted
        font.pixelSize:10;font.family:root.themeFont;font.underline:linkArea.containsMouse;textFormat:Text.PlainText;elide:Text.ElideRight
        MouseArea {
            id:linkArea;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
            onClicked:root.openUrl(linkText.url)
        }
    }
    component Action: Rectangle {
        id:act
        property string text:''
        property bool selected:false
        property color accent:root.tint
        signal clicked()
        implicitWidth:caption.implicitWidth+26;implicitHeight:34
        radius:9;color:act.selected?Qt.alpha(accent,0.18):area.containsMouse?root.surfaceHover:root.surfaceIdle
        border.color:act.selected?accent:area.containsMouse?root.strokeStrong:root.stroke
        Behavior on color {ColorAnimation{duration:120}}
        Text{id:caption;anchors.centerIn:parent;text:act.text;color:act.selected?root.themeText:root.themeSoft;font.pixelSize:12;font.family:root.themeFont;font.bold:act.selected;textFormat:Text.PlainText}
        MouseArea{id:area;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor;onClicked:act.clicked()}
    }
    component Stat: Rectangle {
        property string label:''
        property string value:''
        property string hint:''
        property int valueSize:20
        radius:12;color:root.surface;border.color:root.stroke
        Column {anchors.fill:parent;anchors.margins:12;spacing:5
            Label{text:label;font.pixelSize:10;font.letterSpacing:1;width:parent.width;elide:Text.ElideRight}
            Heading{text:value;font.pixelSize:valueSize;width:parent.width;elide:Text.ElideRight}
            Label{text:hint;font.pixelSize:10;width:parent.width;elide:Text.ElideRight}
        }
    }

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
                    width:parent.width;spacing:10;visible:root.tab===0 // tight: fits a 1000 px screen
                    height:visible?implicitHeight:0
                    Rectangle {
                        width:parent.width;height:170;radius:16;border.color:Qt.alpha(root.tint,0.45)
                        gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.surface}}
                        DiskChip {id:heroChip;body:root.themeBg;glint:root.themeText;x:12;y:5;width:160;height:160;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:root.opened&&root.tab===0&&!root.stale&&root.setting('animated',true)}
                        Column {x:188;y:20;spacing:6
                            Label{text:'FREE SPACE ON '+(root.primary?root.primary.mount:root.mountpoint).toUpperCase();font.pixelSize:11;font.letterSpacing:2}
                            Row {spacing:10
                                Text {text:root.stale||!root.capacityKnown?'—':root.hero.value;color:root.themeText;font.pixelSize:52;font.family:root.themeFont;font.weight:Font.Light}
                                Label{text:root.hero.unit;font.pixelSize:18;anchors.bottom:parent.bottom;anchors.bottomMargin:10}
                            }
                            Label{text:!root.primary?'No filesystem is mounted at '+root.mountpoint:!root.capacityKnown?(root.primary.responsive===false?'Not answering':'Capacity not read yet')+'  ·  '+root.primary.fstype+(root.primary.remote?' · remote':''):Model.pct(root.primary.freePct)+' free  /  '+Model.size(root.primary.total)+' '+root.primary.fstype+(root.primary.encrypted?' on LUKS':'')+(root.drive?' · '+root.drive.transport:'');color:root.themeSoft}
                            Label{text:'Used = size − free, including filesystem metadata.';font.pixelSize:10}
                        }
                        Text {anchors.right:parent.right;anchors.rightMargin:20;anchors.top:parent.top;anchors.topMargin:22;text:(root.capacityKnown?Model.pct(root.primary.usedPct):'—')+'\nused';color:Qt.alpha(root.themeText,0.5);font.pixelSize:15;horizontalAlignment:Text.AlignRight;font.family:root.themeFont}
                    }
                    Row {width:parent.width;spacing:10
                        Stat{width:(parent.width-30)/4;height:90;label:'READING';value:Model.rate(root.rates.read);hint:Model.perSec(root.rates.readIops)+' · all drives'}
                        Stat{width:(parent.width-30)/4;height:90;label:'WRITING';value:Model.rate(root.rates.write);hint:Model.perSec(root.rates.writeIops)+' · all drives'}
                        Stat{width:(parent.width-30)/4;height:90;label:'DRIVE BUSY';value:Model.whole(root.drive&&root.drive.rates?root.drive.rates.util:null);hint:root.drive?'time '+root.drive.name+' spent on I/O':'no drive found'}
                        Stat{width:(parent.width-30)/4;height:90;label:'STORAGE PRESSURE';value:Model.pct(root.pressure);hint:'Time tasks waited on I/O · last 10s'}
                    }
                    Rectangle {width:parent.width;height:214;radius:14;color:root.surface;border.color:root.stroke
                        Column {anchors.fill:parent;anchors.margins:14;spacing:9
                            Row {width:parent.width;spacing:7
                                Heading{text:'CONTINUOUS HISTORY';font.pixelSize:12;width:parent.width-222;anchors.verticalCenter:parent.verticalCenter}
                                Repeater{model:[{t:'1 hour',s:3600},{t:'24 hours',s:86400},{t:'7 days',s:604800}]
                                    Action{required property var modelData;text:modelData.t;selected:root.range===modelData.s;implicitWidth:68;implicitHeight:28;onClicked:root.range=modelData.s}
                                }
                            }
                            DiskHistoryGraph{width:parent.width;height:111;historyData:root.chart;tint:root.tint
                                writeTint:root.themeAccent;busyTint:root.rampWarn;usedTint:root.themeText
                                grid:root.stroke;axisText:root.themeMuted
                                crosshair:root.strokeStrong;hoverBackground:root.surfaceHover
                                hoverBorder:root.stroke;hoverForeground:root.themeText;fontFamily:root.themeFont}
                            Row{spacing:14
                                Label{text:'━ Read';color:root.tint;font.pixelSize:10}
                                Label{text:'━ Write';color:root.themeAccent;font.pixelSize:10}
                                Label{text:'━ Busy %';color:root.rampWarn;font.pixelSize:10}
                                Label{text:'╌ Used %';color:root.themeSoft;font.pixelSize:10}
                                Label{text:'Peak read '+Model.rate(root.chart.peakRead)+'  ·  '+(root.chart.count||0)+' samples';font.pixelSize:10}
                            }
                            Label{text:(root.chart.count||0)<2?'History is starting. Samples accumulate every 15 seconds.':'Recording while closed · 7-day retention · hover to inspect · faint line = read peaks';font.pixelSize:10}
                        }
                    }
                    Rectangle {width:parent.width;height:fsColumn.implicitHeight+28;radius:14;color:root.surface;border.color:root.stroke
                        Column{id:fsColumn;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;anchors.margins:14;spacing:9
                            Item{width:parent.width;height:22
                                Heading{text:'FILESYSTEMS';font.pixelSize:12;anchors.left:parent.left;anchors.verticalCenter:parent.verticalCenter}
                                Row{anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter;spacing:6
                                    Label{visible:root.fsPages<=1;text:root.filesystems.length+' mounted  ·  click one to follow it';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                                    Action{visible:root.fsPages>1;text:'‹';implicitWidth:30;implicitHeight:22;opacity:root.fsPage>0?1:0.4;onClicked:root.fsPage=Math.max(0,root.fsPage-1)}
                                    Label{visible:root.fsPages>1;text:(root.fsPage+1)+' / '+root.fsPages+'  ·  '+root.filesystems.length+' mounted';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                                    Action{visible:root.fsPages>1;text:'›';implicitWidth:30;implicitHeight:22;opacity:root.fsPage+1<root.fsPages?1:0.4;onClicked:root.fsPage=Math.min(root.fsPages-1,root.fsPage+1)}
                                }
                            }
                            Repeater{model:root.fsListing
                                Item {
                                    id:fsRow
                                    required property var modelData
                                    width:fsColumn.width;height:30
                                    readonly property bool followed:modelData.mount===(root.primary?root.primary.mount:'')
                                    readonly property bool known:modelData.responsive!==false&&Model.has(modelData.freePct)
                                    readonly property color own:known?Model.ramp(fsRow.modelData.freePct,root.rampPalette):root.themeMuted
                                    Row{width:parent.width;y:0
                                        Label{width:parent.width*0.55;elide:Text.ElideRight;font.pixelSize:11;color:fsRow.followed?root.themeText:root.themeSoft;font.bold:fsRow.followed
                                            text:fsRow.modelData.mount+'  ·  '+fsRow.modelData.fstype+(root.fsBadges(fsRow.modelData)?'  ·  '+root.fsBadges(fsRow.modelData):'')+(fsRow.modelData.also&&fsRow.modelData.also.length?'  ·  also '+root.alsoList(fsRow.modelData.also):'')}
                                        Label{width:parent.width*0.45;horizontalAlignment:Text.AlignRight;font.pixelSize:11;color:root.themeSoft
                                            text:fsRow.modelData.responsive===false?'not answering'+(Model.has(fsRow.modelData.freePct)?'  ·  last seen '+Model.size(fsRow.modelData.free)+' free':''):Model.has(fsRow.modelData.freePct)?Model.size(fsRow.modelData.free)+' free  ·  '+Model.size(fsRow.modelData.used)+' of '+Model.size(fsRow.modelData.total):'capacity not read'}
                                    }
                                    Rectangle{y:21;width:parent.width;height:5;radius:3;color:root.stroke
                                        Rectangle{width:parent.width*Model.clamp(fsRow.modelData.total?fsRow.modelData.used/fsRow.modelData.total:0,0,1);height:parent.height;radius:3;color:fsRow.own;Behavior on width{NumberAnimation{duration:800}}}
                                    }
                                    MouseArea{anchors.fill:parent;cursorShape:Qt.PointingHandCursor;onClicked:root.setMountpoint(fsRow.modelData.mount)}
                                }
                            }
                            Label{width:parent.width;elide:Text.ElideRight;font.pixelSize:10;text:root.drive?'Drive: '+(root.drive.model||root.drive.name)+'  ·  '+root.drive.transport+' '+(root.drive.rotational?'HDD':'SSD')+'  ·  '+Model.dec(root.drive.size)+'  ·  '+Model.temp(root.drive.temp)+'  ·  scheduler '+root.drive.scheduler:'No physical drive is visible; the filesystems above are all there is.'}
                        }
                    }
                }
                Column {
                    width:parent.width;spacing:6;visible:root.tab===1;height:visible?implicitHeight:0 // tight: fits a 1000 px screen
                    Row{width:parent.width;spacing:8
                        Heading{text:'TOP DISK HOGS';width:parent.width-90;font.pixelSize:13;anchors.verticalCenter:parent.verticalCenter}
                        Label{text:'refresh 9s';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                    }
                    Label{text:'One row per process, ranked by storage traffic right now, then by everything it has ever read and written. Click a row to visit its app or attached session.';width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11}
                    Repeater {
                        model:root.rows.slice(root.page*8,root.page*8+8)
                        Rectangle {
                            id:procRow
                            required property var modelData
                            required property int index
                            width:mainColumn.width;height:65;radius:10
                            color:hogMouse.containsMouse?root.surfaceHover:root.surface;border.color:hogMouse.containsMouse?root.tint:root.stroke
                            Rectangle{anchors.left:parent.left;anchors.bottom:parent.bottom;anchors.leftMargin:12;anchors.bottomMargin:5;width:(parent.width-24)*Model.clamp(root.hogPeak?(Model.num(procRow.modelData.readRate)+Model.num(procRow.modelData.writeRate))/root.hogPeak:0,0,1);height:2;radius:1;color:root.tint}
                            Label{x:12;y:22;text:String(root.page*8+procRow.index+1).padStart(2,'0');font.pixelSize:12;color:root.tint}
                            Column{x:44;y:10;spacing:5;width:parent.width-262
                                Heading{text:procRow.modelData.name+'  ·  '+procRow.modelData.pid;font.pixelSize:13;width:parent.width;elide:Text.ElideRight}
                                Label{text:procRow.modelData.target&&procRow.modelData.target.address?(procRow.modelData.target.host.kind==='herdr'?'Herdr '+procRow.modelData.target.host.pane+' · ':procRow.modelData.target.host.kind==='tmux'?'tmux '+procRow.modelData.target.host.pane+' · ':'')+procRow.modelData.target.title:'Background process · no attached window';width:parent.width;elide:Text.ElideRight;font.pixelSize:10}
                            }
                            Column{anchors.right:parent.right;anchors.rightMargin:35;y:10;spacing:5
                                Heading{text:'R '+Model.rate(procRow.modelData.readRate)+'  ·  W '+Model.rate(procRow.modelData.writeRate);font.pixelSize:14;anchors.right:parent.right}
                                Label{text:'lifetime  read '+Model.dec(procRow.modelData.readTotal)+'  ·  written '+Model.dec(procRow.modelData.writeTotal);font.pixelSize:10;anchors.right:parent.right}
                            }
                            Label{anchors.right:parent.right;anchors.rightMargin:13;y:22;text:procRow.modelData.target&&procRow.modelData.target.address?'↗':'ⓘ';color:root.tint;font.pixelSize:16}
                            MouseArea{id:hogMouse;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
                                onClicked: {if(procRow.modelData.target&&procRow.modelData.target.address)root.runAction('focus',procRow.modelData);else root.actionStatus=procRow.modelData.name+' · PID '+procRow.modelData.pid+' · has read '+Model.dec(procRow.modelData.readTotal)+' and written '+Model.dec(procRow.modelData.writeTotal)+' to storage. No existing window to focus.'}
                            }
                        }
                    }
                    Row{spacing:10
                        Action{text:'← Previous';opacity:root.page>0?1:0.4;onClicked:root.page=Math.max(0,root.page-1)}
                        Label{text:(root.page+1)+' / '+Math.max(1,Math.ceil(root.rows.length/8));anchors.verticalCenter:parent.verticalCenter}
                        Action{text:'Next →';opacity:(root.page+1)*8<root.rows.length?1:0.4;onClicked:root.page=Math.min(Math.max(0,Math.ceil(root.rows.length/8)-1),root.page+1)}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Traffic is what actually reached the storage layer, not reads the page cache answered. Only your own processes expose these counters without privilege, so a system service thrashing the drive shows in the drive\'s own numbers rather than here. Browser subprocesses lead to their browser window.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===2;height:visible?implicitHeight:0
                    // One drive card: the one behind the followed filesystem.
                    // A second drive would push the tab past a 1080p screen,
                    // and panels never scroll; follow one of its filesystems
                    // on the Overview tab to see it here.
                    Row{width:parent.width;visible:root.drive!==null
                        Heading{text:root.drive?(root.drive.model||root.drive.name).toUpperCase():'';font.pixelSize:13;width:parent.width*0.5;elide:Text.ElideRight}
                        Label{text:root.drive?root.drive.name+'  ·  '+root.drive.transport+' '+(root.drive.rotational?'HDD':'SSD')+'  ·  '+Model.dec(root.drive.size)+(root.drive.firmware?'  ·  fw '+root.drive.firmware:''):'';width:parent.width*0.5;horizontalAlignment:Text.AlignRight;font.pixelSize:11;elide:Text.ElideLeft}
                    }
                    Grid{width:parent.width;columns:root.labColumns;spacing:10;visible:root.drive!==null
                        Repeater{model:root.drive?root.driveStats(root.drive):[]
                            Stat{required property var modelData;width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:modelData.l;value:modelData.v;hint:modelData.h}
                        }
                    }
                    Label{visible:root.drive!==null;width:parent.width;elide:Text.ElideRight;font.pixelSize:10;text:root.drive?(root.drive.partitions||[]).length+' partitions  ·  '+(root.drive.discard?'discard supported':'no discard')+'  ·  write cache '+(root.drive.writeCache||'unknown')+'  ·  '+root.drive.logicalBlock+'-byte blocks'+(root.drive.smart&&root.drive.smart.updated?'  ·  SMART read '+Qt.formatTime(new Date(root.drive.smart.updated*1000),'h:mm AP'):'')+(root.disks.length>1?'  ·  also '+root.disks.filter(function(d){return d.name!==root.drive.name}).map(function(d){return d.name+' '+Model.dec(d.size)}).join(', ')+' — follow a filesystem on Overview to inspect':''):''}
                    Label{visible:root.drive===null;width:parent.width;wrapMode:Text.WordWrap;text:'No physical drive is visible from this session: a container, a diskless boot, or a virtual disk the kernel does not expose as a device.';font.pixelSize:11}
                    Rectangle{width:parent.width;height:1;color:root.stroke}
                    Heading{text:root.pool?'BTRFS POOL BEHIND '+(root.primary?root.primary.mount.toUpperCase():'/'):'KERNEL WRITEBACK AND TRIM';font.pixelSize:13}
                    Grid{width:parent.width;columns:root.labColumns;spacing:10;visible:root.pool!==null
                        Repeater{model:root.pool?root.poolStats(root.pool):[]
                            Stat{required property var modelData;width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:modelData.l;value:modelData.v;hint:modelData.h}
                        }
                    }
                    Grid{width:parent.width;columns:root.labColumns;spacing:10
                        Repeater{model:root.kernelStats()
                            Stat{required property var modelData;width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17;label:modelData.l;value:modelData.v;hint:modelData.h}
                        }
                    }
                    Rectangle{width:parent.width;height:84;radius:12;color:Qt.tint(root.themeBg,Qt.alpha(root.rampGood,0.08));border.color:Qt.alpha(root.rampGood,0.42)
                        Column{anchors.left:parent.left;anchors.top:parent.top;anchors.margins:14;width:parent.width-220;spacing:6
                            Heading{text:'SETTLE PENDING WRITES';font.pixelSize:12}
                            Label{width:parent.width;wrapMode:Text.WordWrap;text:'The same unprivileged sync a clean shutdown performs: dirty pages go to disk now, nothing is discarded and no cache is dropped. Briefly busy on the drive; once a minute at most.';font.pixelSize:10;color:root.themeSoft}
                        }
                        Action{anchors.right:parent.right;anchors.rightMargin:14;anchors.verticalCenter:parent.verticalCenter;text:actionProc.running?'Working…':'Flush pending writes';accent:root.rampGood;onClicked:root.runAction('flush')}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Everything here is read from sysfs, procfs and udisks without privilege. No trim, scrub, balance, format, mount, self-test or scheduler change is exposed.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===3;height:visible?implicitHeight:0
                    Rectangle {
                        width:parent.width;height:132;radius:16;border.color:Qt.alpha(root.tint,0.45)
                        gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.surface}}
                        // Still, not animated: an About tab should not be the
                        // most expensive thing the panel draws.
                        DiskChip {x:14;y:6;body:root.themeBg;glint:root.themeText;width:120;height:120;free:root.chipFree;tint:root.tint;animate:false}
                        Column {x:152;y:26;spacing:6
                            Label{text:'VERSION';font.pixelSize:11;font.letterSpacing:2}
                            Heading{text:root.pluginVersion || 'unavailable';font.pixelSize:34;font.letterSpacing:1}
                            Label{text:'Disk Pulse for Omarchy  ·  MIT  ·  Fred Nix';font.pixelSize:11}
                        }
                    }
                    Row {spacing:8
                        Action{text:'Source code on GitHub  →';onClicked:root.openUrl(root.repoUrl)}
                        Action{text:'nixfred.com  →';onClicked:root.openUrl(root.homeUrl)}
                    }
                    // The addresses in full, and selectable: a click opens the
                    // browser, but if no handler is configured the reader still
                    // leaves with somewhere to go.
                    Column {width:parent.width;spacing:4
                        Link{text:root.repoUrl;url:root.repoUrl;font.pixelSize:11}
                        Link{text:root.homeUrl;url:root.homeUrl;font.pixelSize:11}
                    }
                    Rectangle{width:parent.width;height:1;color:root.stroke}
                    // Where this plugin's moving parts live. An About in a
                    // diagnostic tool is the natural place to answer "what is
                    // running and where does it keep things" without a manual.
                    Flow {
                        width:parent.width;spacing:10
                        Stat{width:(mainColumn.width-20)/3;height:91;label:'RECORDER';value:root.stale?'offline':'running';hint:'disk-pulse.service, user unit'}
                        Stat{width:(mainColumn.width-20)/3;height:91;label:'RETENTION';value:'7 days';hint:'aggregate metrics, this machine only'}
                        Stat{width:(mainColumn.width-20)/3;height:91;label:'SAMPLES HELD';value:String(root.chart.count||0);hint:'in the range on screen'}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11;text:'State lives in '+root.stateDir+' and never leaves this machine. Disk Pulse reads unprivileged kernel counters and udisks only: it never trims, scrubs, formats, mounts or writes a tunable. The chip follows '+root.mountpoint+'; the capacity trace in history follows the root filesystem.'}
                }
                Rectangle{width:parent.width;height:1;color:root.stroke}
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10;color:root.stale?root.rampWarn:root.themeSoft;text:root.actionStatus || (root.stale?'Telemetry is offline. Check the disk-pulse user service.':root.disk.collectorErrors && Object.keys(root.disk.collectorErrors).length?'Live storage is available; recorder details are degraded. Check the disk-pulse user service.': 'LIVE · updated '+Qt.formatTime(new Date(root.disk.ts*1000),'h:mm:ss AP')+'  ·  History stays on this machine  ·  Esc closes')}
                // About: version, source, site. At the foot of the panel and in
                // the dim caption colour, so it never competes with the readings
                // — but always present, because you should never have to open a
                // file to learn which Disk Pulse you are looking at. A Flow, not
                // a Row, so a long repo path wraps rather than eliding to nothing.
                Flow {
                    // The About tab states all three at full size; repeating
                    // them a centimetre below would be noise. Every other tab
                    // keeps the caption, which is the whole point of it.
                    visible:root.tab!==3
                    width:parent.width;spacing:6
                    Label{text:'Disk Pulse'+(root.pluginVersion!==''?' v'+root.pluginVersion:'');font.pixelSize:10}
                    Label{text:'·';font.pixelSize:10;visible:root.repoUrl!==''}
                    Link{visible:root.repoUrl!=='';text:root.repoUrl.replace(/^https?:\/\//,'');url:root.repoUrl}
                    Label{text:'·';font.pixelSize:10;visible:root.homeUrl!==''}
                    Link{visible:root.homeUrl!=='';text:root.homeUrl.replace(/^https?:\/\//,'');url:root.homeUrl}
                }
    }
}
