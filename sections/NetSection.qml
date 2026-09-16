import QtQuick
import QtQuick.Controls
import Quickshell.Networking
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "NetModel.js" as Model
import "Constraints.js" as Constraints

// Network section of Pulse — the whole of nixfred.net-pulse's dashboard, hosted
// inside the merged panel. Everything below the host bridge is the original
// plugin's own code, so nothing it measured or showed is lost in the merge.
Item {
    id: root

    // ---- host bridge -------------------------------------------------
    // The merged Panel owns the popup, the bar entry and the settings blob.
    // The section reaches those through `host`, and keeps the member names the
    // original code already used, so the ported body needs no rewriting.
    required property var host
    readonly property string prefix: 'net'
    readonly property string moduleName: host.moduleName
    readonly property var bar: host.bar
    readonly property color barForeground: host.barForeground
    // ---- transparent bar -------------------------------------------------
    // The radio/wired chip drops its fill while the bar is transparent - a
    // square of the bar surface colour would hang over the wallpaper - and a
    // lost signal dims the bar's own ink instead of `muted`, a colour chosen to
    // sit on a slab.
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
    readonly property var tabs: ['Overview','Wi-Fi','Interfaces','Talkers','Data','Network lab','About']
    readonly property int lastTab: root.tabs.length-1
    function setting(key, fallback) { return host.setting(root.prefix+'.'+key, fallback) }
    function setSetting(key, value) { host.setSetting(root.prefix+'.'+key, value) }
    function close() { host.close() }
    function open() { host.openSection(root.prefix) }
    width: parent ? parent.width : 0
    property Item dashboard: null
    implicitHeight: dashboard ? dashboard.implicitHeight : 0

    // Columns are taken from the width the panel actually has, not fixed. On
    // a 1600 px laptop screen that is 3 interface cards and 2 network rows; on
    // a 5120 px ultrawide it is more of each, which is what keeps seven
    // interfaces inside a 1400 px-tall screen instead of stacking three rows.
    readonly property int ifaceColumns: Math.max(2, Math.min(6, Math.floor((root.width + 12) / 400)))
    readonly property int wifiColumns: Math.max(2, Math.min(4, Math.floor((root.width + 12) / 620)))
    readonly property string stateDir: (Quickshell.env('XDG_STATE_HOME') || Quickshell.env('HOME')+'/.local/state')+'/net-pulse'
    readonly property string helper: String(Qt.resolvedUrl('../collectors/net_pulse.py')).replace(/^file:\/\//,'')
    property var net: ({})
    property var histories: ({})
    property var usages: ({})
    property int tab: 0
    property int page: 0
    property int wifiPage: 0
    property int range: 3600
    property int usageRange: 86400
    property bool chooseMode: false
    property string actionStatus: ''
    property real now: Date.now()/1000
    readonly property bool stale: !net.ts || now-net.ts > 12
    readonly property int mode: Model.clamp(setting('displayMode',0),0,4)
    readonly property real health: stale ? 50 : Model.health(net)
    // The link ramp takes the theme's own red, yellow and green. The shell
    // exposes neither green nor yellow, so they come from the theme's palette
    // file; Model.rampStops lifts a muted one and keeps the built-in ramp for
    // a theme whose three stops are really one colour.
    property string palette: ''
    readonly property var rampStops: Model.rampStops(palette)
    readonly property color tint: stale ? Color.muted : Model.ramp(health, rampStops)
    readonly property string chipKind: stale || !net.online ? 'offline' : (Model.isWifi(net) ? 'wifi' : 'ethernet')
    readonly property real activity: Model.clamp(((net.rates||{}).rx||0)/8e6, 0, 1)
    readonly property var rows: (net.talkers||{}).rows || []
    onRowsChanged: page = Math.min(page, Math.max(0, Math.ceil(rows.length/8)-1))
    readonly property var chart: histories[String(range)] || {points:[],seconds:range,now:now,bucket:15,count:0,peakRx:0,peakTx:0,peakLatency:0}
    readonly property var usageChart: usages[String(usageRange)] || {points:[],seconds:Math.max(3600,usageRange),bucket:60,start:now-3600,now:now,totalRx:0,totalTx:0,peak:0,recorded:0,first:null,ifaces:[]}
    readonly property real usageTotal: (usageChart.totalRx||0)+(usageChart.totalTx||0)
    readonly property var wifi: net.wifi || {}
    readonly property var ping: net.ping || {}
    readonly property var iface: net.iface || {}
    // Identity for the About tab. manifest.json is the single source of truth
    // for all three, so bumping a version or moving the repo is one edit there;
    // the constants are only the fallback for when the registry is unreachable.
    readonly property var pluginManifest: {
        var reg = bar && bar.shell ? bar.shell.pluginRegistry : null
        return reg && reg.installedPlugins ? (reg.installedPlugins[root.moduleName] || null) : null
    }
    readonly property string version: pluginManifest && pluginManifest.version ? String(pluginManifest.version) : '1.4.0'
    readonly property string repoUrl: pluginManifest && pluginManifest.repository ? String(pluginManifest.repository) : 'https://github.com/nixfred/omanet.plugin.omarchy'
    readonly property string siteUrl: pluginManifest && pluginManifest.homepage ? String(pluginManifest.homepage) : 'https://nixfred.com'

    // ---- Theme surfaces. The dashboard follows the Omarchy theme: the popup
    // roles for background and text, the accent for anything interactive, and
    // urgent for anything wrong. Cards, rules and dim labels are the theme's
    // background lifted toward its own text rather than fixed slate, so they
    // hold up on a light theme too. The chip's health tint is the deliberate
    // exception: red-amber-green is a reading, not decoration, and it is what
    // makes this widget a sibling of CPU Pulse and RAM Pulse beside it.
    readonly property color themeFg: bar ? bar.foreground : Color.foreground
    readonly property color themeAccent: Color.accent
    readonly property color themeUrgent: bar ? bar.urgent : Color.urgent
    readonly property color panelBg: Color.popups.background
    readonly property color panelText: Color.popups.text
    readonly property color surface: Model.mix(panelBg, panelText, 0.05)
    readonly property color surfaceRaised: Model.mix(panelBg, panelText, 0.08)
    readonly property color surfaceHot: Model.mix(panelBg, panelText, 0.12)
    readonly property color accentSurface: Model.mix(panelBg, themeAccent, 0.12)
    readonly property color accentBorder: Model.mix(panelBg, themeAccent, 0.34)
    readonly property color accentHot: Model.mix(themeAccent, panelText, 0.45)
    readonly property color cardBorder: Model.mix(panelBg, Color.popups.border, 0.5)
    readonly property color hairline: Model.mix(panelBg, panelText, 0.17)
    readonly property color hairlineHot: Model.mix(panelBg, panelText, 0.33)
    readonly property color gridLine: Model.mix(panelBg, panelText, 0.12)
    readonly property color bodyText: Color.muted
    readonly property color dimText: Model.mix(panelBg, Color.muted, 0.72)
    readonly property color captionText: Model.mix(panelBg, panelText, 0.78)

    // ---- NetworkManager objects for Wi-Fi actions (passphrases never touch argv)
    readonly property bool nmAvailable: Networking.backend === NetworkBackendType.NetworkManager
    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var wifiDevice: findDevice(DeviceType.Wifi)
    readonly property var nmNetworks: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
    property var scanDevice: null
    property string wifiSsid: ''
    property string wifiKind: ''
    property string passwordSsid: ''
    property string passwordText: ''
    property var frozenRows: []
    // While a passphrase is being typed the row list is held still: rebuilding
    // the delegate underneath would take the field, its cursor and any
    // in-progress input-method composition with it.
    readonly property var wifiRows: passwordSsid !== '' && frozenRows.length ? frozenRows : mergeWifi(net.networks || [], nmNetworks)
    onPasswordSsidChanged: frozenRows = passwordSsid !== '' ? mergeWifi(net.networks || [], nmNetworks) : []
    onWifiRowsChanged: wifiPage = Math.min(wifiPage, Math.max(0, Math.ceil(wifiRows.length/8)-1))

    function findDevice(type) {
        var fallback=null
        for (var i=0;i<devices.length;i++) { var d=devices[i]; if(!d || d.type!==type) continue; if(d.connected) return d; if(!fallback) fallback=d }
        return fallback
    }
    function netObj(ssid) {
        for (var i=0;i<nmNetworks.length;i++) if(nmNetworks[i] && nmNetworks[i].name===ssid) return nmNetworks[i]
        return null
    }
    function securityName(value) {
        try { var s=WifiSecurityType.toString(value); return s==='None'?'Open':s } catch(e) { return '' }
    }
    function mergeWifi(scan, objects) {
        var out=[], seen={}
        for (var i=0;i<scan.length;i++) {
            var r=Object.assign({}, scan[i]), o=r.hidden?null:netObj(r.ssid)
            r.known=o?!!o.known:false; r.connected=o?!!o.connected:!!r.inUse; r.changing=o?!!o.stateChanging:false; r.actionable=!!o
            out.push(r); if(!r.hidden) seen[r.ssid]=true
        }
        for (var j=0;j<objects.length;j++) {
            var n=objects[j]
            if(!n || !n.name || seen[n.name]) continue
            out.push({ssid:n.name,hidden:false,aps:1,inUse:!!n.connected,bands:[],band:'',channel:0,freq:0,rate:0,width:0,signal:Math.round((n.signalStrength||0)*100),security:securityName(n.security),known:!!n.known,connected:!!n.connected,changing:!!n.stateChanging,actionable:true})
        }
        out.sort(function(a,b){ if(a.connected!==b.connected) return a.connected?-1:1; if(a.known!==b.known) return a.known?-1:1; return b.signal-a.signal })
        return out
    }
    function needsPassphrase(row) { var s=Model.security(row.security); return s!=='Open' && s!=='Enhanced open' }
    function wifiAct(kind, ssid) {
        if(wifiKind) return
        var n=netObj(ssid)
        if(!n){ actionStatus='NetworkManager has not listed '+ssid+' yet. Give the scan a moment.'; return }
        wifiSsid=ssid; wifiKind=kind
        actionStatus=(kind==='connect'?'Connecting to ':kind==='disconnect'?'Disconnecting from ':'Forgetting ')+ssid+'…'
        if(kind==='connect') n.connect(); else if(kind==='disconnect') n.disconnect(); else n.forget()
        wifiTimeout.restart()
    }
    function wifiConnectPsk(ssid, psk) {
        if(wifiKind || !psk) return
        var n=netObj(ssid)
        if(!n){ actionStatus='NetworkManager has not listed '+ssid+' yet.'; return }
        wifiSsid=ssid; wifiKind='connect'; actionStatus='Connecting to '+ssid+'…'
        n.connectWithPsk(psk); passwordText=''
        wifiTimeout.restart()
    }
    // 802.1X needs a CA certificate, an EAP method and a server-name check to be
    // safe, and its password must never reach a command line. That belongs in the
    // system editor, which handles all three; this panel only opens it.
    function setUpEnterprise(ssid) {
        if(!root.bar) return
        actionStatus='Opening the connection editor for '+ssid+'. Enterprise networks need their CA certificate.'
        root.bar.run('omarchy-launch-floating-terminal-with-presentation '+Util.shellQuote('nmtui connect'))
        root.close()
    }
    function rowClicked(row) {
        if(!row.actionable || row.hidden || wifiKind) { if(row.hidden) actionStatus='Hidden networks need their name; add them with nmtui.'; return }
        if(row.connected){ wifiAct('disconnect',row.ssid); return }
        if(Model.security(row.security)==='Enterprise' && !row.known){ setUpEnterprise(row.ssid); return }
        if(needsPassphrase(row) && !row.known){ passwordSsid=row.ssid; passwordText=''; return }
        wifiAct('connect',row.ssid)
    }
    function wifiDone(message) { wifiTimeout.stop(); wifiKind=''; wifiSsid=''; passwordSsid=''; actionStatus=message }
    function wifiFailed(reason) {
        var ssid=wifiSsid, row=null
        for (var i=0;i<wifiRows.length;i++) if(wifiRows[i].ssid===ssid) row=wifiRows[i]
        var secured=row?needsPassphrase(row):true
        var text=reason===ConnectionFailReason.NoSecrets&&secured?'needs a passphrase':reason===ConnectionFailReason.WifiAuthTimeout&&secured?'rejected the passphrase':reason===ConnectionFailReason.WifiNetworkLost?'went out of range':'refused the connection'
        wifiDone(ssid+' '+text+'.')
        if(secured && (reason===ConnectionFailReason.NoSecrets || reason===ConnectionFailReason.WifiAuthTimeout)) { passwordSsid=ssid; passwordText='' }
    }
    function syncScanner() {
        var want=opened && tab===1 && !chooseMode && wifiDevice
        if(want && scanDevice!==wifiDevice){ if(scanDevice) scanDevice.scannerEnabled=false; scanDevice=wifiDevice; scanDevice.scannerEnabled=true }
        else if(!want && scanDevice){ scanDevice.scannerEnabled=false; scanDevice=null }
    }
    function setMode(value) {
        root.setSetting('displayMode', Model.clamp(value,0,4))
    }
    function runAction(action, args, working) {
        if(actionProc.running) return
        actionStatus=working || 'Working…'
        actionProc.command=['python3',helper,action].concat(args||[])
        actionProc.running=true
    }
    // Addresses go to the clipboard as an argument, never through a shell string.
    function copy(value, what) {
        var text = String(value || '').trim()
        if (!text) return
        Quickshell.execDetached(['wl-copy', text])
        actionStatus = 'Copied ' + (what ? what + ' ' : '') + text + ' to the clipboard.'
    }
    // Links go to the desktop handler as an argument, never through a shell string.
    function openUrl(url) {
        var target = String(url || '')
        if (!/^https:\/\//.test(target)) return
        actionStatus = 'Opened ' + target + ' in your browser.'
        close()
        Quickshell.execDetached(['xdg-open', target])
    }
    function summon(target, payload) {
        if(root.bar && root.bar.shell) { root.close(); root.bar.shell.summon(target, JSON.stringify(payload||{})) }
    }
    function editConnection(uuid) {
        if(!root.bar || !/^[0-9a-fA-F-]{36}$/.test(uuid)) return
        root.bar.run('omarchy-launch-floating-terminal-with-presentation '+Util.shellQuote('nmtui-edit '+uuid))
        root.close()
    }
    function status() {
        return JSON.stringify({version:version,opened:opened,mode:mode,readout:Model.readout(net,mode),tint:String(tint),stale:stale,online:!!net.online,health:health,iface:iface.name||'',kind:chipKind,ssid:wifi.ssid||'',rx:(net.rates||{}).rx||0,tx:(net.rates||{}).tx||0,latency:ping.internet,samples:chart.count||0,tab:tab,chooseMode:chooseMode,networks:wifiRows.length,interfaces:(net.interfaces||[]).length,talkers:rows.length,wifiAction:wifiKind,action:actionStatus,usageRange:usageRange,usedRx:usageChart.totalRx||0,usedTx:usageChart.totalTx||0,usedFor:usageChart.recorded||0})
    }
    onOpenedChanged: { if(opened){ snapshotFile.reload(); historyFile.reload(); usageFile.reload() } syncScanner() }
    onTabChanged: { page=0; wifiPage=0; syncScanner(); if(panel && scroller) scroller.contentY=0 }
    onChooseModeChanged: syncScanner()
    onWifiDeviceChanged: syncScanner()
    Component.onDestruction: if(scanDevice) scanDevice.scannerEnabled=false
    FileView {
        id:snapshotFile; path:root.stateDir+'/snapshot.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{var m=JSON.parse(text());if(m.ts>0)root.net=m}catch(e){}}
    }
    FileView {
        id:historyFile; path:root.stateDir+'/history.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{root.histories=JSON.parse(text())}catch(e){}}
    }
    FileView {
        id:usageFile; path:root.stateDir+'/usage.json'; watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:{try{root.usages=JSON.parse(text())}catch(e){}}
    }
    FileView {
        // The theme's own palette file. watchChanges covers a theme edited in
        // place; a theme switch is caught by themeSignature below.
        id:paletteFile
        path:Quickshell.env('HOME')+'/.local/state/omarchy/current/theme/colors.toml'
        watchChanges:true; printErrors:false
        onFileChanged:reload()
        onLoaded:root.palette=text()
    }
    // The shell reads colors.toml once at startup and is pushed later palettes
    // over IPC, so the watcher alone would strand the ramp on the previous
    // theme. Re-read whenever the shell's own colours move, which is exactly
    // when that push lands.
    readonly property string themeSignature: String(Color.background)+String(Color.foreground)+String(Color.accent)+String(Color.urgent)
    onThemeSignatureChanged: paletteFile.reload()
    // Width floors for the bar readout, measured by hidden labels rather than by
    // TextMetrics: only an identical Text arrives at an identical implicitWidth,
    // and the third of a pixel the two disagree by is still a resize.
    Timer { interval:2000; running:true; repeat:true; onTriggered:{root.now=Date.now()/1000; if(root.stale)snapshotFile.reload()} }
    Timer {
        id:wifiPoll; interval:500; repeat:true; running:root.wifiKind!==''
        onTriggered:{
            var n=root.netObj(root.wifiSsid)
            if(!n){ if(root.wifiKind==='forget') root.wifiDone('Forgot '+root.wifiSsid+'.'); return }
            if(root.wifiKind==='connect' && n.connected) root.wifiDone('Connected to '+root.wifiSsid+'.')
            else if(root.wifiKind==='disconnect' && !n.connected && !n.stateChanging) root.wifiDone('Disconnected from '+root.wifiSsid+'.')
            else if(root.wifiKind==='forget' && !n.known && !n.stateChanging) root.wifiDone('Forgot '+root.wifiSsid+'.')
        }
    }
    // Outlasts NetworkManager's 25-second supplicant timeout so a wrong saved passphrase still reports as such.
    Timer { id:wifiTimeout; interval:30000; onTriggered:if(root.wifiKind) root.wifiDone('Timed out while '+(root.wifiKind==='connect'?'connecting to ':root.wifiKind==='disconnect'?'disconnecting from ':'forgetting ')+root.wifiSsid+'.') }
    Connections {
        target: root.wifiKind ? root.netObj(root.wifiSsid) : null
        ignoreUnknownSignals: true
        function onConnectionFailed(reason) { root.wifiFailed(reason) }
    }
    Process {
        id:actionProc
        stdout:StdioCollector { onStreamFinished:{try{var r=JSON.parse(text);root.actionStatus=r.error || r.message || 'Done';if(!r.error && r.message && r.message.indexOf('Focused ')===0)root.close()}catch(e){root.actionStatus='Action could not complete.'}} }
        onExited:function(code){if(code!==0 && root.actionStatus.indexOf('…')>=0)root.actionStatus='Action could not complete.'}
    }
    function currentDns() {
        var links=(net.dns||{}).links||[]
        for (var i=0;i<links.length;i++) if(links[i].name===iface.name && links[i].current) return links[i].current
        for (var j=0;j<links.length;j++) if(links[j].name!=='Global' && links[j].servers && links[j].servers.length) return links[j].servers[0]
        // A host can resolve entirely through systemd-resolved's global servers.
        for (var k=0;k<links.length;k++) if(links[k].servers && links[k].servers.length) return links[k].current || links[k].servers[0]
        return '—'
    }
    function dnsCount() {
        var links=(net.dns||{}).links||[], n=0
        for (var i=0;i<links.length;i++) if(links[i].name!=='Global') n+=(links[i].servers||[]).length
        if (n===0) for (var j=0;j<links.length;j++) n+=(links[j].servers||[]).length
        return n
    }

    // ---- summary surface ----------------------------------------------
    readonly property string verdict: root.stale ? 'WAITING FOR TELEMETRY' : Model.healthLabel(root.net)
    readonly property string sectionTitle: 'Network'
    readonly property string sectionBlurb: 'Your connection, in motion.'
    // The bar-readout chooser, rendered by the merged Settings page.
    readonly property int modeCount: 5
    readonly property string modeHint: 'Choose what lives beside the chip.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   ·   '+Model.readout(root.net,index) }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.net(root.net, root.stale)
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
    readonly property string headline: root.stale ? '—' : Model.readout(root.net, root.mode)
    readonly property string tag: Model.modeTag(root.net, root.mode)
    property Component barChip: Component { NetChip {compact:true;body:root.barTransparent?'transparent':Color.bar.background;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.barTint;stops:root.rampStops;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { NetChip {width:88;height:88;body:Color.popups.background;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint;stops:root.rampStops;animate:root.cardLive} }
    property Component cardGraph: Component { NetHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;latencyTint:root.themeUrgent;upTint:root.themeAccent;axisText:root.dimText;gridLine:root.gridLine;tipBackground:Color.tooltip.background;tipBorder:Color.tooltip.border;tipText:Color.tooltip.text} }

    component Label: Text { color:root.bodyText;font.pixelSize:12;textFormat:Text.PlainText }
    component Heading: Text { color:root.panelText;font.pixelSize:15;font.bold:true;textFormat:Text.PlainText }
    component Action: Rectangle {
        id:act
        property string text:''
        property bool selected:false
        property bool enabled:true
        property color accent:root.themeAccent
        signal clicked()
        implicitWidth:caption.implicitWidth+26;implicitHeight:34
        radius:9;color:act.selected?Qt.alpha(accent,0.18):area.containsMouse&&act.enabled?root.surfaceHot:root.surface
        border.color:act.selected?accent:area.containsMouse&&act.enabled?root.hairlineHot:root.hairline
        opacity:act.enabled?1:0.45
        Behavior on color {ColorAnimation{duration:120}}
        Text{id:caption;anchors.centerIn:parent;text:act.text;color:act.selected?root.panelText:root.captionText;font.pixelSize:12;font.bold:act.selected;textFormat:Text.PlainText}
        MouseArea{id:area;anchors.fill:parent;hoverEnabled:true;cursorShape:act.enabled?Qt.PointingHandCursor:Qt.ArrowCursor;onClicked:if(act.enabled)act.clicked()}
    }
    component Stat: Rectangle {
        id:stat
        property string label:''
        property string value:''
        property string hint:''
        property string copyText:''
        property string copyWhat:''
        property int elideMode: Text.ElideRight
        readonly property bool copyable: copyText !== ''
        radius:12
        color:stat.copyable&&statArea.containsMouse?root.surfaceHot:root.surface
        border.color:stat.copyable&&statArea.containsMouse?Qt.alpha(root.themeAccent,0.6):root.hairline
        Behavior on color {ColorAnimation{duration:110}}
        Column {anchors.fill:parent;anchors.margins:12;spacing:5
            Label{text:stat.label;font.pixelSize:10;font.letterSpacing:1}
            // Long addresses shrink to fit rather than losing their last octets.
            Heading{text:stat.value;font.pixelSize:20;width:parent.width;elide:stat.elideMode
                fontSizeMode:Text.HorizontalFit;minimumPixelSize:10}
            Label{text:stat.hint;font.pixelSize:10;width:parent.width;elide:Text.ElideRight}
        }
        Text{visible:stat.copyable&&statArea.containsMouse;text:'⧉';color:root.themeAccent;font.pixelSize:12;textFormat:Text.PlainText
            anchors.right:parent.right;anchors.top:parent.top;anchors.rightMargin:8;anchors.topMargin:6}
        MouseArea{id:statArea;anchors.fill:parent;hoverEnabled:stat.copyable;enabled:stat.copyable
            cursorShape:Qt.PointingHandCursor;onClicked:root.copy(stat.copyText,stat.copyWhat)}
    }
    component Node: Rectangle {
        id:node
        property string label:''
        property string value:''
        property string hint:''
        property bool ok:true
        property string copyWhat:''
        readonly property bool copyable: Model.isAddress(node.value)
        radius:10
        color:node.copyable&&nodeArea.containsMouse?root.surfaceHot:root.surface
        border.color:node.copyable&&nodeArea.containsMouse?root.tint:node.ok?Qt.alpha(root.tint,0.5):root.themeUrgent
        Behavior on color {ColorAnimation{duration:110}}
        Column{anchors.centerIn:parent;spacing:3;width:parent.width-16
            Label{text:node.label;font.pixelSize:9;font.letterSpacing:1;horizontalAlignment:Text.AlignHCenter;width:parent.width}
            Heading{text:node.value;font.pixelSize:12;horizontalAlignment:Text.AlignHCenter;width:parent.width;elide:Text.ElideMiddle
                fontSizeMode:Text.HorizontalFit;minimumPixelSize:9}
            Label{text:node.hint;font.pixelSize:9;horizontalAlignment:Text.AlignHCenter;width:parent.width;elide:Text.ElideRight;color:node.ok?root.bodyText:root.themeUrgent}
        }
        MouseArea{id:nodeArea;anchors.fill:parent;hoverEnabled:node.copyable;enabled:node.copyable
            cursorShape:Qt.PointingHandCursor;onClicked:root.copy(node.value,node.copyWhat)}
    }
    component Link: Rectangle {
        id:link
        property string label:''
        property string url:''
        height:38;radius:10
        color:linkArea.containsMouse?root.surfaceHot:root.surface
        border.color:linkArea.containsMouse?root.themeAccent:root.hairline
        Behavior on color {ColorAnimation{duration:110}}
        Label{anchors.left:parent.left;anchors.leftMargin:12;anchors.verticalCenter:parent.verticalCenter
            text:link.label;font.pixelSize:10;font.letterSpacing:1}
        Text{anchors.right:parent.right;anchors.rightMargin:12;anchors.verticalCenter:parent.verticalCenter
            text:link.url;color:linkArea.containsMouse?root.accentHot:root.themeAccent;font.pixelSize:11;textFormat:Text.PlainText}
        MouseArea{id:linkArea;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
            acceptedButtons:Qt.LeftButton|Qt.RightButton
            onClicked:function(event){if(event.button===Qt.RightButton)root.copy(link.url,'the link to');else root.openUrl(link.url)}}
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
                        gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.13)}GradientStop{position:1;color:root.surface}}
                        NetChip {x:12;y:5;width:160;height:160;body:root.surfaceRaised;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint;stops:root.rampStops;animate:root.opened&&root.tab===0&&!root.stale&&root.setting('animated',true)}
                        Column {x:188;y:18;spacing:5;width:parent.width-330
                            Label{text:'DOWNLOAD  ·  UPLOAD';font.pixelSize:11;font.letterSpacing:2}
                            Row {spacing:14
                                Text {text:root.stale||!root.net.online?'—':Model.rate((root.net.rates||{}).rx);color:root.panelText;font.pixelSize:42;font.weight:Font.Light}
                                Text {text:root.stale||!root.net.online?'':'↑ '+Model.rate((root.net.rates||{}).tx);color:root.themeAccent;font.pixelSize:20;font.weight:Font.Light;anchors.bottom:parent.bottom;anchors.bottomMargin:8;textFormat:Text.PlainText}
                            }
                            Label{text:root.stale?'Waiting for the net-pulse service.':!root.net.online?'No default route. Nothing is carrying traffic to the internet.':(Model.isWifi(root.net)?root.wifi.ssid+'  ·  '+(root.wifi.band||'')+(root.wifi.channel?' channel '+root.wifi.channel:''):(root.iface.connection||Model.kindName(root.iface.kind)))+'  ·  '+root.iface.name+'  ·  '+((root.iface.addrs4||[])[0]||(root.iface.addrs6||[])[0]||'no address').split('/')[0];color:root.panelText;width:parent.width;elide:Text.ElideRight}
                            Label{text:root.net.online?'Gateway '+(root.iface.gateway||'—')+' · '+Model.ms(root.ping.gateway)+'    Internet '+(root.ping.probe||'1.1.1.1')+' · '+Model.ms(root.ping.internet)+(Model.num(root.ping.loss)>0?'  ·  '+Model.whole(root.ping.loss)+' loss':'')+'    ·  click any address to copy it':'Pings pause until a route appears.';font.pixelSize:10}
                        }
                        Text {anchors.right:parent.right;anchors.rightMargin:20;anchors.top:parent.top;anchors.topMargin:22;horizontalAlignment:Text.AlignRight;color:Qt.alpha(root.panelText,0.5);font.pixelSize:15;textFormat:Text.PlainText
                            text:root.stale||!root.net.online?'':Model.isWifi(root.net)?Model.whole(root.wifi.quality)+'\nsignal':Model.mbit(root.iface.speed)+'\nlink'}
                    }
                    Row {width:parent.width;spacing:10
                        Stat{width:(parent.width-30)/4;height:96;label:'LATENCY';value:Model.ms(root.ping.internet);hint:'Gateway '+Model.ms(root.ping.gateway)+' · loss '+Model.whole(root.ping.loss)}
                        Stat{width:(parent.width-30)/4;height:96;label:Model.isWifi(root.net)?'SIGNAL':'LINK';value:Model.isWifi(root.net)?Model.dbm(root.wifi.signal):Model.mbit(root.iface.speed);hint:Model.isWifi(root.net)?Model.whole(root.wifi.quality)+' quality · '+(root.wifi.generation||''):(root.iface.duplex?root.iface.duplex+' duplex · ':'')+'MTU '+(root.iface.mtu||'—')}
                        Stat{width:(parent.width-30)/4;height:96;label:'THIS ADDRESS';value:Model.bare((root.iface.addrs4||[])[0]||(root.iface.addrs6||[])[0]||'—')
                            hint:'↓ '+Model.size((root.net.totals||{}).rx)+' ↑ '+Model.size((root.net.totals||{}).tx)+' on '+(root.iface.name||'—')
                            copyText:Model.bare((root.iface.addrs4||[])[0]||(root.iface.addrs6||[])[0]);copyWhat:'this address'}
                        Stat{width:(parent.width-30)/4;height:96;label:'CONNECTIVITY';value:root.net.online?String(root.net.connectivity||'unknown').replace(/^./,function(c){return c.toUpperCase()}):'Offline';hint:'DNS via '+((root.net.dns||{}).provider||'—')+' · '+String(root.net.nmState||'')}
                    }
                    Rectangle {width:parent.width;height:242;radius:14;color:root.surface;border.color:root.hairline
                        Column {anchors.fill:parent;anchors.margins:14;spacing:9
                            Item {width:parent.width;height:30
                                Heading{anchors.left:parent.left;anchors.verticalCenter:parent.verticalCenter;text:'CONTINUOUS HISTORY';font.pixelSize:12}
                                Row{anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter;spacing:7
                                    Repeater{model:[{t:'1 hour',s:3600},{t:'24 hours',s:86400},{t:'7 days',s:604800}]
                                        Action{required property var modelData;text:modelData.t;selected:root.range===modelData.s;implicitWidth:68;implicitHeight:28;onClicked:root.range=modelData.s}
                                    }
                                }
                            }
                            NetHistoryGraph{width:parent.width;height:139;historyData:root.chart;tint:root.tint
                            latencyTint:root.themeUrgent;upTint:root.themeAccent;axisText:root.dimText;gridLine:root.gridLine;tipBackground:Color.tooltip.background;tipBorder:Color.tooltip.border;tipText:Color.tooltip.text}
                            Row{spacing:14
                                Label{text:'━ Download';color:root.tint;font.pixelSize:10}
                                Label{text:'━ Upload';color:root.themeAccent;font.pixelSize:10}
                                Label{text:'┅ Latency';color:root.themeUrgent;font.pixelSize:10}
                                Label{text:'Peak ↓ '+Model.rate(root.chart.peakRx)+'  ·  ↓ '+Model.size(root.chart.totalRx)+' ↑ '+Model.size(root.chart.totalTx)+' in range  ·  '+(root.chart.count||0)+' samples';font.pixelSize:10}
                            }
                            Label{text:(root.chart.count||0)<2?'History is starting. Samples accumulate every 15 seconds.':'Recording while closed · 7-day retention · hover to inspect · faint line = download peaks';font.pixelSize:10}
                        }
                    }
                    Rectangle {width:parent.width;height:112;radius:14;color:root.surfaceRaised;border.color:root.cardBorder
                        Column{anchors.fill:parent;anchors.margins:14;spacing:9
                            Heading{text:'PATH TO THE INTERNET';font.pixelSize:12}
                            Row{width:parent.width;spacing:0
                                Node{width:(parent.width-3*22)/4;height:60;label:'THIS DEVICE';value:Model.bare((root.iface.addrs4||[])[0]||(root.iface.addrs6||[])[0]||'—');hint:root.iface.name?root.iface.name+' · '+(root.iface.mac||''):'no interface';ok:!!root.net.online;copyWhat:'this address'}
                                Label{text:'→';width:22;horizontalAlignment:Text.AlignHCenter;anchors.verticalCenter:parent.verticalCenter;color:root.themeAccent;font.pixelSize:16}
                                Node{width:(parent.width-3*22)/4;height:60;label:'GATEWAY';value:root.iface.gateway||'—';hint:Model.ms(root.ping.gateway)+' round trip';ok:Model.num(root.ping.gateway)>=0||!Model.has(root.ping.gateway);copyWhat:'the gateway'}
                                Label{text:'→';width:22;horizontalAlignment:Text.AlignHCenter;anchors.verticalCenter:parent.verticalCenter;color:root.themeAccent;font.pixelSize:16}
                                Node{width:(parent.width-3*22)/4;height:60;label:'DNS';value:currentDns();hint:((root.net.dns||{}).provider||'—')+' · '+dnsCount()+' servers';ok:true;copyWhat:'the resolver'}
                                Label{text:'→';width:22;horizontalAlignment:Text.AlignHCenter;anchors.verticalCenter:parent.verticalCenter;color:root.themeAccent;font.pixelSize:16}
                                Node{width:(parent.width-3*22)/4;height:60;label:'INTERNET';value:root.ping.probe||'1.1.1.1';hint:Model.ms(root.ping.internet)+' round trip · '+String(root.net.connectivity||'unknown');ok:Model.num(root.ping.internet)>=0||!Model.has(root.ping.internet);copyWhat:'the probe target'}
                            }
                        }
                    }
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===1;height:visible?implicitHeight:0
                    Item{width:parent.width;height:32
                        Heading{anchors.left:parent.left;anchors.verticalCenter:parent.verticalCenter;text:'RADIO';font.pixelSize:13}
                        Row{anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter;spacing:8
                            Action{text:Networking.wifiEnabled?'Wi-Fi on':'Wi-Fi off';selected:Networking.wifiEnabled;enabled:root.nmAvailable&&!!root.wifiDevice;implicitHeight:30;onClicked:{Networking.wifiEnabled=!Networking.wifiEnabled;root.actionStatus=Networking.wifiEnabled?'Turning the radio off…':'Turning the radio on…'}}
                            Action{text:'Rescan';enabled:!!root.wifiDevice&&Networking.wifiEnabled;implicitHeight:30;onClicked:root.runAction('rescan',[],'Scanning for nearby networks…')}
                            Action{text:'Share QR';enabled:Model.isWifi(root.net);implicitHeight:30;onClicked:root.summon('omarchy.wifiqr',{iface:root.iface.name,ssid:root.wifi.ssid})}
                        }
                    }
                    Rectangle{visible:!root.wifiDevice;width:parent.width;height:visible?70:0;radius:12;color:root.surface;border.color:root.hairline
                        Label{anchors.centerIn:parent;text:root.nmAvailable?'No Wi-Fi radio is known to NetworkManager on this machine.':'NetworkManager is not available; Wi-Fi controls are inert.'}
                    }
                    Rectangle {visible:Model.isWifi(root.net);width:parent.width;height:visible?196:0;radius:16;border.color:Qt.alpha(root.tint,0.45)
                        gradient:Gradient {GradientStop{position:0;color:Qt.alpha(root.tint,0.10)}GradientStop{position:1;color:root.surface}}
                        Column{anchors.fill:parent;anchors.margins:14;spacing:10
                            Row{width:parent.width
                                Column{width:parent.width-260;spacing:3
                                    Heading{text:root.wifi.ssid||'—';font.pixelSize:18;width:parent.width;elide:Text.ElideRight}
                                    Label{text:(root.wifi.bssid||'').toUpperCase()+'  ·  '+Model.security(root.wifi.security)+'  ·  '+(root.wifi.generation||'')+'  ·  '+(root.iface.driver||'');font.pixelSize:10}
                                }
                                Label{text:'connected '+Model.ago(root.wifi.connectedSeconds);width:260;horizontalAlignment:Text.AlignRight;color:root.panelText}
                            }
                            Grid{width:parent.width;columns:3;spacing:10
                                Stat{width:(parent.width-20)/3;height:62;label:'SIGNAL';value:Model.dbm(root.wifi.signal)+'  ·  '+Model.whole(root.wifi.quality);hint:'average '+Model.dbm(root.wifi.signalAvg)+' · tx power '+(Model.has(root.wifi.txPower)?root.wifi.txPower+' dBm':'—')}
                                Stat{width:(parent.width-20)/3;height:62;label:'CHANNEL';value:(root.wifi.channel?'CH '+root.wifi.channel:'—')+'  ·  '+(root.wifi.band||'');hint:(root.wifi.width?root.wifi.width+' MHz wide':'')+(root.wifi.freq?' · '+root.wifi.freq+' MHz':'')}
                                Stat{width:(parent.width-20)/3;height:62;label:'LINK RATE';value:'↑ '+Model.mbit(root.wifi.txBitrate);hint:'↓ '+Model.mbit(root.wifi.rxBitrate)+' · '+(root.wifi.txMode||'')}
                            }
                            Label{text:'Retries '+Model.count(root.wifi.retries)+'  ·  failed '+Model.count(root.wifi.failed)+'  ·  beacon loss '+Model.count(root.wifi.beaconLoss)+'  ·  ↓ '+Model.size(root.wifi.rxBytes)+' ↑ '+Model.size(root.wifi.txBytes)+' on this association';font.pixelSize:10}
                        }
                    }
                    Row{visible:!!root.wifiDevice&&((root.net.band||{}).available||[]).length>0;width:parent.width;spacing:8
                        Label{text:'WI-FI BAND';font.pixelSize:10;font.letterSpacing:1;anchors.verticalCenter:parent.verticalCenter;width:90}
                        Repeater{model:['auto'].concat(((root.net.band||{}).available||[]).filter(function(b){return ['2.4','5','6'].indexOf(b)>=0}))
                            Action{required property string modelData;text:modelData==='auto'?'Automatic':modelData+' GHz';selected:((root.net.band||{}).selected||'auto')===modelData;implicitHeight:28;enabled:Model.isWifi(root.net);onClicked:root.runAction('band',[modelData],'Pinning the band and reassociating…')}
                        }
                        Label{text:'now on '+((root.net.band||{}).band?(root.net.band.band+' GHz'):'—');font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                    }
                    Row{width:parent.width;visible:!!root.wifiDevice
                        Heading{text:'NEARBY NETWORKS';width:parent.width-260;font.pixelSize:13}
                        Label{text:root.wifiRows.length+' networks · scanning while this tab is open';font.pixelSize:10;width:260;horizontalAlignment:Text.AlignRight}
                    }
                    Flow{width:parent.width;spacing:12
                    Repeater {
                        model:root.wifiRows.slice(root.wifiPage*8,root.wifiPage*8+8)
                        Rectangle {
                            id:wrow
                            required property var modelData
                            required property int index
                            readonly property bool prompting:root.passwordSsid!==''&&root.passwordSsid===modelData.ssid
                            readonly property bool busy:root.wifiKind!==''&&root.wifiSsid===modelData.ssid
                            readonly property bool enterprise:Model.security(modelData.security)==='Enterprise'
                            width:(mainColumn.width-12*(root.wifiColumns-1))/root.wifiColumns;height:prompting?92:58;radius:10
                            color:wmouse.containsMouse||prompting?root.surfaceHot:root.surface;border.color:modelData.connected?root.themeAccent:wmouse.containsMouse?root.hairlineHot:root.hairline
                            Behavior on height{NumberAnimation{duration:140}}
                            // Declared first so every button below sits above it.
                            MouseArea{id:wmouse;x:0;y:0;width:parent.width;height:58;hoverEnabled:true;cursorShape:Qt.PointingHandCursor;onClicked:root.rowClicked(wrow.modelData)}
                            Rectangle{x:12;y:44;width:(parent.width-24)*Model.clamp(wrow.modelData.signal/100,0,1);height:2;radius:1;color:wrow.modelData.connected?root.themeAccent:root.dimText}
                            Label{x:12;y:19;text:Model.whole(wrow.modelData.signal);font.pixelSize:12;color:wrow.modelData.connected?root.themeAccent:root.bodyText;width:34}
                            Column{x:52;y:9;spacing:4;width:parent.width-300
                                Heading{text:(wrow.modelData.hidden?'Hidden network':wrow.modelData.ssid)+(wrow.modelData.aps>1?'  ·  '+wrow.modelData.aps+' access points':'');font.pixelSize:13;width:parent.width;elide:Text.ElideRight;color:wrow.modelData.hidden?root.bodyText:root.panelText}
                                Label{text:Model.security(wrow.modelData.security)+(wrow.modelData.band?'  ·  '+(wrow.modelData.bands&&wrow.modelData.bands.length>1?wrow.modelData.bands.join(' + '):wrow.modelData.band):'')+(wrow.modelData.channel?'  ·  CH '+wrow.modelData.channel:'')+(wrow.modelData.rate?'  ·  up to '+Model.mbit(wrow.modelData.rate):'')+(wrow.modelData.width?'  ·  '+wrow.modelData.width+' MHz':'');font.pixelSize:10;width:parent.width;elide:Text.ElideRight}
                            }
                            Row{anchors.right:parent.right;anchors.rightMargin:12;y:12;spacing:8
                                Label{visible:wrow.modelData.known&&!wrow.modelData.connected&&!wrow.busy;text:'saved';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                                Action{visible:wrow.modelData.known&&!wrow.modelData.connected&&!wrow.busy&&root.wifiKind==='';text:'Forget';implicitHeight:28;implicitWidth:66;onClicked:root.wifiAct('forget',wrow.modelData.ssid)}
                                Label{text:wrow.busy?(root.wifiKind==='connect'?'Connecting…':root.wifiKind==='disconnect'?'Disconnecting…':'Forgetting…'):wrow.modelData.connected?'Connected  ·  disconnect ⏏':wrow.modelData.hidden?'':wrow.modelData.known?'connect ↗':wrow.enterprise?'set up 🔐':root.needsPassphrase(wrow.modelData)?'passphrase 🔒':'open · connect ↗';color:wrow.modelData.connected?root.themeAccent:root.captionText;font.pixelSize:11;anchors.verticalCenter:parent.verticalCenter}
                            }
                            Column{visible:wrow.prompting;x:52;y:54;width:parent.width-64;spacing:6
                                Row{width:parent.width;spacing:8
                                    TextField{id:pwField;width:parent.width-190;password:true;placeholderText:'Passphrase';font.family:Style.font.family;font.pixelSize:12;text:wrow.prompting?root.passwordText:'';onTextChanged:if(wrow.prompting&&text!==root.passwordText)root.passwordText=text
                                        onAccepted:if(root.passwordText.length>=8)root.wifiConnectPsk(wrow.modelData.ssid,root.passwordText)
                                        Keys.onEscapePressed:root.passwordSsid=''
                                        onVisibleChanged:if(visible)Qt.callLater(forceActiveFocus)}
                                    Action{text:'Connect';implicitHeight:30;implicitWidth:86;enabled:root.passwordText.length>=8;onClicked:root.wifiConnectPsk(wrow.modelData.ssid,root.passwordText)}
                                    Action{text:'Cancel';implicitHeight:30;implicitWidth:80;onClicked:{root.passwordSsid='';root.passwordText=''}}
                                }
                            }
                        }
                    }
                    } // end of the two-column Wi-Fi Flow
                    Row{spacing:10;visible:root.wifiRows.length>8
                        Action{text:'← Previous';opacity:root.wifiPage>0?1:0.4;onClicked:root.wifiPage=Math.max(0,root.wifiPage-1)}
                        Label{text:(root.wifiPage+1)+' / '+Math.max(1,Math.ceil(root.wifiRows.length/8));anchors.verticalCenter:parent.verticalCenter}
                        Action{text:'Next →';opacity:(root.wifiPage+1)*8<root.wifiRows.length?1:0.4;onClicked:root.wifiPage=Math.min(Math.max(0,Math.ceil(root.wifiRows.length/8)-1),root.wifiPage+1)}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Connect, disconnect and forget go through NetworkManager as your user. Passphrases travel over D-Bus, never on a command line, and are not stored by this plugin. Enterprise (802.1X) networks open in the system connection editor, which is where their CA certificate and server name belong. Band pins reassociate and may drop the link for a few seconds.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===2;height:visible?implicitHeight:0
                    Row{width:parent.width
                        Heading{text:'EVERY INTERFACE';width:parent.width-260;font.pixelSize:13}
                        Label{text:(root.net.interfaces||[]).length+' links · loopback hidden';font.pixelSize:10;width:260;horizontalAlignment:Text.AlignRight}
                    }
                    Rectangle{visible:!(root.net.interfaces||[]).some(function(i){return i.kind==='ethernet'});width:parent.width;height:visible?44:0;radius:10;color:root.surface;border.color:root.hairline
                        Label{anchors.centerIn:parent;text:'No wired Ethernet adapter is present. A USB or dock adapter appears here the moment the kernel sees it.';font.pixelSize:11}
                    }
                    Flow{width:parent.width;spacing:12 // interfaces: two columns of cards
                    Repeater{
                        model:root.net.interfaces||[]
                        Rectangle{
                            id:card
                            required property var modelData
                            readonly property var s:modelData.settings||{}
                            readonly property var profiles:modelData.profiles||[]
                            readonly property bool external:String((modelData.nm||{}).state||'').indexOf('externally')>=0
                            readonly property bool managed:!!(modelData.nm&&modelData.nm.uuid)
                            // A saved profile is a way back even with nothing active.
                            readonly property string actionUuid:managed?modelData.nm.uuid:(profiles.length?profiles[0].uuid:'')
                            readonly property string actionName:managed?modelData.nm.connection:(profiles.length?profiles[0].name:'')
                            readonly property bool connected:modelData.nm&&String(modelData.nm.state||'').indexOf('connected')===0
                            width:(mainColumn.width-12*(root.ifaceColumns-1))/root.ifaceColumns;height:col.implicitHeight+28;radius:14;color:modelData.active?root.surfaceRaised:root.surface;border.color:modelData.active?Qt.alpha(root.themeAccent,0.5):root.hairline
                            Column{id:col;anchors.fill:parent;anchors.margins:14;spacing:10
                                Row{width:parent.width
                                    Column{width:parent.width-250;spacing:3
                                        Heading{text:card.modelData.name+'  ·  '+Model.kindName(card.modelData.kind)+(card.modelData.active?'  ·  default route':'');font.pixelSize:14;color:card.modelData.active?root.panelText:root.captionText}
                                        Label{text:(card.modelData.nm&&card.modelData.nm.connection?'“'+card.modelData.nm.connection+'”  ·  ':'')+String(card.modelData.operstate||'').toUpperCase()+(card.modelData.carrier?'  ·  carrier':'  ·  no carrier')+(card.modelData.driver?'  ·  '+card.modelData.driver:'')+'  ·  '+(card.modelData.mac||'').toUpperCase();font.pixelSize:10;width:parent.width;elide:Text.ElideRight}
                                    }
                                    Label{text:'↓ '+Model.rate(card.modelData.rates.rx)+'   ↑ '+Model.rate(card.modelData.rates.tx);width:250;horizontalAlignment:Text.AlignRight;color:root.panelText}
                                }
                                Grid{id:ifaceGrid;width:parent.width;columns:2;spacing:8
                                    Stat{width:(parent.width-8)/2;height:66;label:'IPv4';value:((card.modelData.addrs4||[])[0]||'—')
                                        hint:(card.modelData.addrs6||[]).length?(card.modelData.addrs6.length+' IPv6 · '+Model.bare(card.modelData.addrs6[0])):'no global IPv6'
                                        copyText:Model.bare((card.modelData.addrs4||[])[0]);copyWhat:card.modelData.name+' IPv4'}
                                    Stat{width:(parent.width-8)/2;height:66;label:card.modelData.kind==='ethernet'?'LINK':'MTU · LINK';value:card.modelData.kind==='ethernet'?Model.mbit(card.modelData.speed):'MTU '+card.modelData.mtu;hint:card.modelData.kind==='ethernet'?(card.modelData.duplex?card.modelData.duplex+' duplex · ':'')+'MTU '+card.modelData.mtu:card.modelData.kind==='wifi'&&card.modelData.active?'↑ '+Model.mbit(root.wifi.txBitrate)+' radio':(card.modelData.nm&&card.modelData.nm.type)||card.modelData.kind}
                                    Stat{width:(parent.width-8)/2;height:66;label:(card.modelData.addrs6||[]).length?'IPv6':'TOTALS'
                                        value:(card.modelData.addrs6||[]).length?Model.bare(card.modelData.addrs6[0]):'↓ '+Model.size(card.modelData.stats.rx)
                                        hint:(card.modelData.addrs6||[]).length?'↓ '+Model.size(card.modelData.stats.rx)+' ↑ '+Model.size(card.modelData.stats.tx):'↑ '+Model.size(card.modelData.stats.tx)+' · '+Model.count(card.modelData.stats.rxPackets+card.modelData.stats.txPackets)+' packets'
                                        copyText:(card.modelData.addrs6||[]).length?Model.bare(card.modelData.addrs6[0]):'';copyWhat:card.modelData.name+' IPv6'
                                        elideMode:(card.modelData.addrs6||[]).length?Text.ElideMiddle:Text.ElideRight}
                                    Stat{width:(parent.width-8)/2;height:66;label:'ERRORS · DROPS';value:Model.count(card.modelData.stats.rxErrors+card.modelData.stats.txErrors)+'  ·  '+Model.count(card.modelData.stats.rxDropped+card.modelData.stats.txDropped);hint:'rx '+card.modelData.stats.rxErrors+'/'+card.modelData.stats.rxDropped+' · tx '+card.modelData.stats.txErrors+'/'+card.modelData.stats.txDropped}
                                }
                                Label{visible:card.managed;width:parent.width;elide:Text.ElideRight;font.pixelSize:10;color:root.bodyText
                                    text:'IPv4 '+(card.s.method4||'—')+(card.s.addresses4?' '+card.s.addresses4:'')+(card.s.gateway4?' via '+card.s.gateway4:'')+'  ·  IPv6 '+(card.s.method6||'—')+'  ·  DNS '+(card.s.dns4?card.s.dns4+(card.s.ignoreAutoDns?' (DHCP DNS ignored)':''):'from DHCP')+'  ·  autoconnect '+(card.s.autoconnect?'on':'off')+(card.s.metered&&card.s.metered!=='unknown'?'  ·  metered '+card.s.metered:'')+(card.s.wakeOnLan&&card.s.wakeOnLan!=='default'?'  ·  wake-on-LAN '+card.s.wakeOnLan:'')}
                                Flow{width:parent.width;spacing:8
                                    Action{visible:card.actionUuid!==''&&!card.external;text:card.connected?'Disconnect':'Connect'+(card.managed?'':' “'+card.actionName+'”');implicitHeight:28;enabled:!actionProc.running&&(card.modelData.kind!=='wifi'||!card.connected);onClicked:root.runAction('connection',[card.connected?'down':'up',card.actionUuid],(card.connected?'Deactivating ':'Activating ')+card.actionName+'…')}
                                    Action{visible:card.actionUuid!=='';text:'Autoconnect '+(card.s.autoconnect?'on':'off');selected:!!card.s.autoconnect;implicitHeight:28;enabled:!actionProc.running&&card.managed;onClicked:root.runAction('autoconnect',[card.actionUuid,card.s.autoconnect?'no':'yes'],'Updating autoconnect…')}
                                    Action{visible:card.actionUuid!=='';text:'Edit connection…';implicitHeight:28;onClicked:root.editConnection(card.actionUuid)}
                                    Label{visible:card.actionUuid==='';text:card.external?'Managed outside NetworkManager ('+card.modelData.nm.state+')':card.profiles.length===0&&card.modelData.kind!=='virtual'?'No saved profile for this device':'Not managed by NetworkManager';font.pixelSize:10;height:28;verticalAlignment:Text.AlignVCenter}
                                    Label{visible:!card.managed&&card.actionUuid!=='';text:'saved profile · not active';font.pixelSize:10;height:28;verticalAlignment:Text.AlignVCenter}
                                    Label{visible:card.managed&&card.modelData.kind==='wifi'&&card.connected;text:'Wi-Fi disconnects live on the Wi-Fi tab';font.pixelSize:10;height:28;verticalAlignment:Text.AlignVCenter}
                                }
                            }
                        }
                    }
                    } // end of the two-column interfaces Flow
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Click any address to copy it. Edit connection… opens nmtui for the full IPv4/IPv6, DNS, MTU and wake-on-LAN settings in a floating terminal. Connect and disconnect act on the saved NetworkManager profile as your user; nothing here changes system files.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:10;visible:root.tab===3;height:visible?implicitHeight:0
                    Row{width:parent.width
                        Heading{text:'TOP TALKERS';width:parent.width-260;font.pixelSize:13}
                        Label{text:'Ranked by open sockets · refresh 9s';font.pixelSize:10;width:260;horizontalAlignment:Text.AlignRight}
                    }
                    Label{text:'Click a row to visit its app or attached session. Background processes show details.';font.pixelSize:11}
                    Repeater {
                        model:root.rows.slice(root.page*8,root.page*8+8)
                        Rectangle {
                            id:procRow
                            required property var modelData
                            required property int index
                            width:mainColumn.width;height:65;radius:10
                            color:talkerMouse.containsMouse?root.surfaceHot:root.surface;border.color:talkerMouse.containsMouse?root.tint:root.hairline
                            Rectangle{anchors.left:parent.left;anchors.bottom:parent.bottom;anchors.leftMargin:12;anchors.bottomMargin:5;width:(parent.width-24)*Model.clamp(procRow.modelData.count/Math.max(1,(root.net.talkers||{}).total||1),0,1);height:2;radius:1;color:root.themeAccent}
                            Label{x:12;y:22;text:String(root.page*8+procRow.index+1).padStart(2,'0');font.pixelSize:12;color:root.themeAccent}
                            Column{x:44;y:10;spacing:5;width:parent.width-232
                                Heading{text:procRow.modelData.name+'  ·  '+procRow.modelData.pid;font.pixelSize:13;width:parent.width;elide:Text.ElideRight}
                                Label{text:(procRow.modelData.target&&procRow.modelData.target.address?(procRow.modelData.target.host.kind==='herdr'?'Herdr '+procRow.modelData.target.host.pane+' · ':procRow.modelData.target.host.kind==='tmux'?'tmux '+procRow.modelData.target.host.pane+' · ':'')+procRow.modelData.target.title+'  ·  ':'')+procRow.modelData.hosts+' host'+(procRow.modelData.hosts===1?'':'s')+': '+(procRow.modelData.remotes||[]).map(function(r){return r.host+(r.count>1?' ×'+r.count:'')+' ('+r.kind+')'}).join(', ');width:parent.width;elide:Text.ElideRight;font.pixelSize:10}
                            }
                            Column{anchors.right:parent.right;anchors.rightMargin:35;y:10;spacing:5
                                Heading{text:procRow.modelData.count+' socket'+(procRow.modelData.count===1?'':'s');font.pixelSize:15;anchors.right:parent.right}
                                Label{text:procRow.modelData.tcp+' tcp · '+procRow.modelData.udp+' udp';font.pixelSize:10;anchors.right:parent.right}
                            }
                            Label{anchors.right:parent.right;anchors.rightMargin:13;y:22;text:procRow.modelData.target&&procRow.modelData.target.address?'↗':'ⓘ';color:root.themeAccent;font.pixelSize:16}
                            MouseArea{id:talkerMouse;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
                                onClicked: {if(procRow.modelData.target&&procRow.modelData.target.address)root.runAction('focus',[String(procRow.modelData.pid),String(procRow.modelData.start)],'Finding the existing window…');else root.actionStatus=procRow.modelData.name+' · PID '+procRow.modelData.pid+' · '+procRow.modelData.count+' open sockets to '+procRow.modelData.hosts+' hosts. No existing window to focus.'}
                            }
                        }
                    }
                    Rectangle{visible:root.rows.length===0;width:parent.width;height:visible?60:0;radius:10;color:root.surface;border.color:root.hairline
                        Label{anchors.centerIn:parent;text:root.stale?'Waiting for the net-pulse service.':'No process has an open connection right now.'}
                    }
                    Row{spacing:10
                        Action{text:'← Previous';opacity:root.page>0?1:0.4;onClicked:root.page=Math.max(0,root.page-1)}
                        Label{text:(root.page+1)+' / '+Math.max(1,Math.ceil(root.rows.length/8));anchors.verticalCenter:parent.verticalCenter}
                        Action{text:'Next →';opacity:(root.page+1)*8<root.rows.length?1:0.4;onClicked:root.page=Math.min(Math.max(0,Math.ceil(root.rows.length/8)-1),root.page+1)}
                        Label{text:((root.net.talkers||{}).total||0)+' active sockets  ·  '+((root.net.talkers||{}).listening||0)+' listening ports  ·  '+((root.net.talkers||{}).anonymous||0)+' owned by other users';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Counts come from ss and are exact. Per-process bandwidth needs packet capture privileges, so it is not shown. Browser subprocesses lead to their browser window.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===4;height:visible?implicitHeight:0
                    Row {width:parent.width;spacing:8
                        Repeater{model:Model.RANGES
                            Action{required property var modelData;text:Model.rangeName(modelData);selected:root.usageRange===modelData;onClicked:root.usageRange=modelData}
                        }
                    }
                    Grid{width:parent.width;columns:4;spacing:8
                        Stat{width:(mainColumn.width-24)/4;height:80;label:'DOWNLOADED';value:Model.size(root.usageChart.totalRx)
                            hint:Model.pace(root.usageChart.totalRx,root.usageChart.recorded)}
                        Stat{width:(mainColumn.width-24)/4;height:80;label:'UPLOADED';value:Model.size(root.usageChart.totalTx)
                            hint:Model.pace(root.usageChart.totalTx,root.usageChart.recorded)}
                        Stat{width:(mainColumn.width-24)/4;height:80;label:'TOTAL';value:Model.size(root.usageTotal)
                            hint:root.usageTotal>0?Math.round((root.usageChart.totalRx||0)/root.usageTotal*100)+'% down  ·  '+Math.round((root.usageChart.totalTx||0)/root.usageTotal*100)+'% up':'nothing moved yet'}
                        Stat{width:(mainColumn.width-24)/4;height:80;label:'RECORDED';value:(root.usageChart.recorded||0)<60?'—':Model.ago(root.usageChart.recorded)
                            hint:root.usageChart.first?'recording since '+Qt.formatDate(new Date(root.usageChart.first*1000),'d MMM yyyy'):'no history yet'}
                    }
                    Rectangle{width:parent.width;height:184;radius:14;color:root.surface;border.color:root.hairline
                        UsageGraph{anchors.fill:parent;anchors.margins:11;usageData:root.usageChart;tint:root.tint
                            baseLine:root.hairline;upTint:root.themeAccent;axisText:root.dimText;gridLine:root.gridLine;tipBackground:Color.tooltip.background;tipBorder:Color.tooltip.border;tipText:Color.tooltip.text
                            visible:(root.usageChart.points||[]).length>0}
                        Label{anchors.centerIn:parent;visible:(root.usageChart.points||[]).length===0
                            text:'Nothing recorded in '+Model.rangeWhen(root.usageRange)+' yet.'}
                    }
                    Row{width:parent.width
                        Heading{text:'BY INTERFACE';font.pixelSize:13;width:parent.width/2}
                        Label{width:parent.width/2;horizontalAlignment:Text.AlignRight;font.pixelSize:10
                            text:'↓ download   ↑ upload  ·  '+Model.coverage(root.usageChart.recorded,root.usageChart.seconds)}
                    }
                    Column{width:parent.width;spacing:6
                        Repeater{model:root.usageChart.ifaces||[]
                            Item{id:usageRow;required property var modelData;width:parent.width;height:34
                                readonly property real total:(modelData[1]||0)+(modelData[2]||0)
                                Rectangle{anchors.fill:parent;radius:9;color:root.surface;border.color:root.hairline}
                                // The fill is the interface's share of the range, so one
                                // busy tunnel is obvious without reading the numbers.
                                Rectangle{height:parent.height;radius:9;color:Qt.alpha(root.themeAccent,0.16)
                                    width:Math.max(3,parent.width*(root.usageTotal>0?usageRow.total/root.usageTotal:0))}
                                Label{x:12;anchors.verticalCenter:parent.verticalCenter;color:root.panelText;font.pixelSize:12;text:usageRow.modelData[0]}
                                Label{anchors.right:parent.right;anchors.rightMargin:12;anchors.verticalCenter:parent.verticalCenter;font.pixelSize:11
                                    text:'↓ '+Model.size(usageRow.modelData[1])+'    ↑ '+Model.size(usageRow.modelData[2])+'    ·    '+Model.size(usageRow.total)}
                            }
                        }
                        Label{visible:(root.usageChart.ifaces||[]).length===0;text:'No interface has moved anything in this range.';font.pixelSize:11}
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10
                        text:'Totals are the bytes this machine actually moved, summed from the rate over each recorded interval — not counters since boot, so a reboot does not reset them. The last hour comes from 15-second samples; longer ranges come from an hourly rollup kept for five years. Nothing is recorded while the collector is stopped, and that missing time is left out of the averages rather than counted as idle.'}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===5;height:visible?implicitHeight:0
                    Rectangle{width:parent.width;height:dnsCol.implicitHeight+28;radius:14;color:root.surfaceRaised;border.color:root.cardBorder
                        Column{id:dnsCol;anchors.fill:parent;anchors.margins:14;spacing:9
                            Item{width:parent.width;height:30
                                Heading{anchors.left:parent.left;anchors.verticalCenter:parent.verticalCenter;text:'DNS';font.pixelSize:12}
                                Row{anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter;spacing:8
                                    Repeater{model:['DHCP','Cloudflare','Google']
                                        Action{required property string modelData;text:modelData;selected:((root.net.dns||{}).provider||'')===modelData;implicitHeight:28;enabled:!actionProc.running;onClicked:root.runAction('dns',[modelData],'Switching DNS to '+modelData+'…')}
                                    }
                                    Action{text:'Flush cache';implicitHeight:28;enabled:!actionProc.running;onClicked:root.runAction('flushdns',[],'Flushing the resolver cache…')}
                                }
                            }
                            Repeater{model:((root.net.dns||{}).links||[]).filter(function(l){return (l.servers||[]).length>0})
                                Item{required property var modelData;width:dnsCol.width;height:18
                                    Label{id:dnsLine;anchors.fill:parent;elide:Text.ElideRight;font.pixelSize:11;color:dnsMouse.containsMouse?root.accentHot:root.themeAccent
                                        text:parent.modelData.name+'  ·  answering: '+(parent.modelData.current||'—')+'  ·  servers: '+(parent.modelData.servers||[]).join(', ')+(parent.modelData.domains&&parent.modelData.domains.length?'  ·  domains: '+parent.modelData.domains.join(' '):'')+(parent.modelData.defaultRoute?'  ·  default route':'')+(parent.modelData.dnssec?'  ·  DNSSEC '+parent.modelData.dnssec:'')}
                                    MouseArea{id:dnsMouse;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor
                                        onClicked:root.copy(Model.bare(String(parent.modelData.current||(parent.modelData.servers||[])[0]||'').split('#')[0]),'the resolver for '+parent.modelData.name)}
                                }
                            }
                            Label{text:'Provider switches use omarchy-dns, the same privileged path as the stock widget. DHCP hands resolution back to the router.';font.pixelSize:10}
                        }
                    }
                    Rectangle{width:parent.width;height:104;radius:14;color:root.accentSurface;border.color:root.accentBorder
                        Column{anchors.fill:parent;anchors.margins:14;spacing:9
                            Row{width:parent.width
                                Heading{text:'PROBES';font.pixelSize:12;width:parent.width/2}
                                Label{text:'Connectivity: '+String(root.net.connectivity||'unknown')+(Networking.connectivityCheckEnabled?' · NetworkManager checks enabled':' · checks off');width:parent.width/2;horizontalAlignment:Text.AlignRight;color:root.bodyText;font.pixelSize:11}
                            }
                            Row{spacing:8
                                Action{text:actionProc.running?'Working…':'10-ping latency burst';accent:root.themeAccent;enabled:!actionProc.running&&!!root.net.online;onClicked:root.runAction('latency',[],'Sending 10 pings to the gateway and '+(root.ping.probe||'1.1.1.1')+'…')}
                                Action{text:'Public address';accent:root.themeAccent;enabled:!actionProc.running&&!!root.net.online;onClicked:root.runAction('publicip',[],'Asking api.ipify.org for the public address…')}
                                Action{text:'Re-check connectivity';accent:root.themeAccent;enabled:Networking.canCheckConnectivity;onClicked:{Networking.checkConnectivity();root.actionStatus='Asked NetworkManager to re-check connectivity.'}}
                                Action{text:'Speed test';accent:root.themeAccent;enabled:!!root.net.online;onClicked:root.summon('omarchy.speedtest',{connection:Model.isWifi(root.net)?root.wifi.ssid:(root.iface.connection||'Ethernet')})}
                            }
                            Label{text:'Public address is the only probe that leaves your network beyond pings; it runs only when you press it.';font.pixelSize:10;color:root.bodyText}
                        }
                    }
                    Heading{text:'TRANSPORT';font.pixelSize:13}
                    Grid{width:parent.width;columns:4;spacing:8
                        Repeater{model:[
                            {l:'ESTABLISHED',v:Model.count((root.net.tcp||{}).CurrEstab),h:'TCP connections right now'},
                            {l:'RETRANSMITS',v:Model.perSec((root.net.tcpRates||{}).RetransSegs),h:Model.count((root.net.tcp||{}).RetransSegs)+' since boot'},
                            {l:'NEW CONNECTIONS',v:Model.perSec(((root.net.tcpRates||{}).ActiveOpens||0)+((root.net.tcpRates||{}).PassiveOpens||0)),h:'outbound + inbound opens'},
                            {l:'SEGMENTS',v:'↓ '+Model.perSec((root.net.tcpRates||{}).InSegs),h:'↑ '+Model.perSec((root.net.tcpRates||{}).OutSegs)},
                            {l:'TCP SOCKETS',v:Model.count((root.net.tcp||{}).tcpInuse),h:Model.count((root.net.tcp||{}).tcpTw)+' time-wait · '+Model.count((root.net.tcp||{}).tcpOrphan)+' orphan'},
                            {l:'UDP SOCKETS',v:Model.count((root.net.tcp||{}).udpInuse),h:'in use'},
                            {l:'LISTENING PORTS',v:Model.count((root.net.talkers||{}).listening),h:'TCP + UDP, all addresses'},
                            {l:'RESETS · FAILS',v:Model.count((root.net.tcp||{}).OutRsts)+'  ·  '+Model.count((root.net.tcp||{}).AttemptFails),h:'RSTs sent · connect attempts failed'},
                            {l:'IP FORWARDING',v:root.net.forwarding?'On':'Off',h:root.net.forwarding?'this machine routes packets':'kernel drops transit packets'},
                            {l:'ACTIVE MTU',v:String(root.iface.mtu||'—'),h:root.iface.name||'no interface'},
                            {l:'LINK ERRORS',v:Model.count(((root.net.totals||{}).rxErrors||0)+((root.net.totals||{}).txErrors||0)),h:Model.count(((root.net.totals||{}).rxDropped||0)+((root.net.totals||{}).txDropped||0))+' dropped'},
                            {l:'PACKET LOSS',v:Model.whole(root.ping.loss),h:'last '+(root.ping.internetSamples||[]).length+' internet pings'}
                        ]
                            Stat{required property var modelData;width:(mainColumn.width-24)/4;height:80;label:modelData.l;value:modelData.v;hint:modelData.h}
                        }
                    }
                    Heading{text:'ROUTES';font.pixelSize:13}
                    Column{width:parent.width;spacing:5
                        Repeater{model:root.net.routes||[]
                            Item{required property var modelData;width:parent.width;height:18
                                Label{anchors.fill:parent;elide:Text.ElideRight;font.pixelSize:11
                                    color:routeMouse.containsMouse&&parent.modelData.gateway?root.accentHot:parent.modelData.dst==='default'?root.panelText:root.themeAccent
                                    text:(parent.modelData.dst==='default'?'default':parent.modelData.dst)+(parent.modelData.gateway?'  via '+parent.modelData.gateway:'')+'  dev '+parent.modelData.dev+(parent.modelData.metric?'  metric '+parent.modelData.metric:'')+(parent.modelData.protocol?'  ·  '+parent.modelData.protocol:'')}
                                MouseArea{id:routeMouse;anchors.fill:parent;hoverEnabled:!!parent.modelData.gateway;enabled:!!parent.modelData.gateway
                                    cursorShape:Qt.PointingHandCursor;onClicked:root.copy(parent.modelData.gateway,'the gateway for '+parent.modelData.dst)}
                            }
                        }
                    }
                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Nothing here edits routes, firewall rules, sysctl or NetworkManager system files. Counters are kernel totals since boot; rates are per second over the last sample.';font.pixelSize:10}
                }
                Column {
                    width:parent.width;spacing:12;visible:root.tab===6;height:visible?implicitHeight:0
                    Rectangle{width:parent.width;height:aboutCol.implicitHeight+28;radius:14;color:root.surfaceRaised;border.color:root.cardBorder
                        Column{id:aboutCol;anchors.fill:parent;anchors.margins:14;spacing:12
                            Row{width:parent.width;spacing:14
                                NetChip{width:64;height:64;body:root.surfaceRaised;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint
                                    animate:root.opened&&root.tab===6&&!root.stale&&root.setting('animated',true)}
                                Column{anchors.verticalCenter:parent.verticalCenter;spacing:5
                                    Heading{text:'Net Pulse';font.pixelSize:20;font.letterSpacing:2}
                                    Label{text:'Version '+root.version+'   ·   MIT licence   ·   Fred Nix';font.pixelSize:11}
                                }
                            }
                            Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:11
                                text:'A living network chip for the Omarchy bar: throughput, latency, Wi-Fi radio detail, interface settings, seven-day history and focus-only top talkers. Everything it records stays on this machine.'}
                            Link{width:parent.width;label:'REPOSITORY';url:root.repoUrl}
                            Link{width:parent.width;label:'AUTHOR';url:root.siteUrl}
                            Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10
                                text:'Click a link to open it in your browser; right-click to copy it instead. Bugs and feature requests go to the repository.'}
                        }
                    }
                }
                Rectangle{width:parent.width;height:1;color:root.hairline}
                Label{width:parent.width;wrapMode:Text.WordWrap;font.pixelSize:10;color:root.stale?root.themeUrgent:root.bodyText;text:root.actionStatus || (root.stale?'Telemetry is offline. Check the net-pulse user service.': 'LIVE · updated '+Qt.formatTime(new Date(root.net.ts*1000),'h:mm:ss AP')+'  ·  History stays on this machine  ·  Esc closes')}
        }
    }
}
