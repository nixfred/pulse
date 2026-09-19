import re,os,sys
import tempfile
SRC=os.path.expanduser('~/.config/omarchy/plugins/')
DST=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))+'/'

# The GPU domain is deliberately absent from every dict in this file.
#
# This script builds a Section by reading an installed upstream plugin's
# Panel.qml and transplanting its body (see the `for name,sp in SPEC.items()`
# loop, which opens SRC/<pid>/Panel.qml). GPU Pulse never existed as its own
# plugin, so there is nothing to transplant: adding a 'Gpu' entry here would
# fail on that open(). sections/GpuSection.qml, GpuModel.js, GpuChip.qml and
# GpuHistoryGraph.qml are hand-written against the same contracts and are not
# generated, not patched, and not overwritten by a run of this script.
#
# The corollary still applies to the other four: this script OVERWRITES their
# sections, models, chips and graphs, so any change made to accommodate the
# GPU domain has to live in SUMMARY/MODEL_PATCHES/LAYOUT_PATCHES below, never
# in the generated files themselves.
def write_text_atomic(dst, text):
    d = os.path.dirname(os.path.abspath(dst)) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(dst) + '.', dir=d)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(text)
        os.replace(tmp, dst)
    except:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

SPEC={
 'Cpu': dict(pid='nixfred.cpu-pulse', key='cpu', title='CPU', blurb='Your processor, in motion.',
             tabs=['Overview','CPU hogs','Processor lab','About'], extra_imports=[]),
 'Ram': dict(pid='nixfred.ram-pulse', key='ram', title='RAM', blurb='Your memory, in motion.',
             tabs=['Overview','RAM hoarders','Memory lab','About'], extra_imports=[]),
 'Disk':dict(pid='nixfred.disk-pulse',key='disk',title='Disk', blurb='Your storage, in motion.',
             tabs=['Overview','Disk hogs','Storage lab','About'], extra_imports=[]),
 'Net': dict(pid='nixfred.net-pulse', key='net', title='Network', blurb='Your network, in motion.',
             tabs=['Overview','Wi-Fi','Interfaces','Talkers','Data','Network lab','About'],
             extra_imports=['import QtQuick.Controls','import Quickshell.Networking']),
}


SUMMARY={
 'Cpu': """
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
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   \u00b7   '+Model.readout(root.cpu,index) }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.cpu(root.cpu, root.stale)
    // The worst row that is actually a constraint, skipping the rows that only
    // describe how the machine is set up.
    readonly property var topConstraint: Constraints.leading(root.constraints)
    readonly property real concern: root.topConstraint ? root.topConstraint.severity : 0
    readonly property string constraintLabel: root.topConstraint ? root.topConstraint.label : 'No constraint'
    readonly property string constraintValue: root.topConstraint ? root.topConstraint.value : '\u2014'
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
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.cpu, root.mode)
    readonly property string tag: Model.modeTag(root.mode)
    property Component barChip: Component { CpuChip {compact:true;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.background;glint:root.bar?root.bar.foreground:root.ink;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { CpuChip {width:88;height:88;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.popups.background;glint:root.ink;animate:root.cardLive} }
    property Component cardGraph: Component { CpuHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;heat:root.heat;ink:root.ink;surface:Color.popups.background} }
""",
 'Ram': """
    // ---- summary surface ----------------------------------------------
    readonly property string verdict: root.health
    readonly property string sectionTitle: 'RAM'
    readonly property string sectionBlurb: 'Your memory, in motion.'
    // The bar-readout chooser, rendered by the merged Settings page.
    readonly property int modeCount: 4
    readonly property string modeHint: 'Choose what lives beside the chip. One decimal.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   \u00b7   '+Model.readout(root.mem,index) }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.ram(root.mem, root.stale)
    // The worst row that is actually a constraint, skipping the rows that only
    // describe how the machine is set up.
    readonly property var topConstraint: Constraints.leading(root.constraints)
    readonly property real concern: root.topConstraint ? root.topConstraint.severity : 0
    readonly property string constraintLabel: root.topConstraint ? root.topConstraint.label : 'No constraint'
    readonly property string constraintValue: root.topConstraint ? root.topConstraint.value : '\u2014'
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
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.mem, root.mode)
    readonly property string tag: root.mode===1||root.mode===2 ? 'USED' : 'AVAILABLE'
    property Component barChip: Component { MemoryChip {compact:true;body:root.themeBg;available:root.mem.availablePct || 0;tint:root.tint;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { MemoryChip {width:88;height:88;body:Color.popups.background;available:root.mem.availablePct || 0;tint:root.tint;animate:root.cardLive} }
    property Component cardGraph: Component { RamHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;swapTint:root.themeAccent;grid:root.stroke;axisText:root.themeMuted;crosshair:root.strokeStrong;hoverBackground:root.surfaceHover;hoverBorder:root.stroke;hoverForeground:root.themeText;fontFamily:root.themeFont} }
""",
 'Net': """
    // ---- summary surface ----------------------------------------------
    readonly property string verdict: root.stale ? 'WAITING FOR TELEMETRY' : Model.healthLabel(root.net)
    readonly property string sectionTitle: 'Network'
    readonly property string sectionBlurb: 'Your connection, in motion.'
    // The bar-readout chooser, rendered by the merged Settings page.
    readonly property int modeCount: 5
    readonly property string modeHint: 'Choose what lives beside the chip.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   \u00b7   '+Model.readout(root.net,index) }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.net(root.net, root.stale)
    // The worst row that is actually a constraint, skipping the rows that only
    // describe how the machine is set up.
    readonly property var topConstraint: Constraints.leading(root.constraints)
    readonly property real concern: root.topConstraint ? root.topConstraint.severity : 0
    readonly property string constraintLabel: root.topConstraint ? root.topConstraint.label : 'No constraint'
    readonly property string constraintValue: root.topConstraint ? root.topConstraint.value : '\u2014'
    // Sliced once per data change. Slicing inside a Repeater's model binding
    // hands it a new array identity on every evaluation, which destroys and
    // rebuilds every delegate each time.
    readonly property var topConstraints: root.constraints.slice(0, 3)
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.net, root.mode)
    readonly property string tag: Model.modeTag(root.net, root.mode)
    property Component barChip: Component { NetChip {compact:true;body:Color.bar.background;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint;stops:root.rampStops;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { NetChip {width:88;height:88;body:Color.popups.background;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint;stops:root.rampStops;animate:root.cardLive} }
    property Component cardGraph: Component { NetHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;latencyTint:root.themeUrgent;upTint:root.themeAccent;axisText:root.dimText;gridLine:root.gridLine;tipBackground:Color.tooltip.background;tipBorder:Color.tooltip.border;tipText:Color.tooltip.text} }
""",
 'Disk': """
    // ---- summary surface ----------------------------------------------
    readonly property string verdict: root.health
    readonly property string sectionTitle: 'Disk'
    readonly property string sectionBlurb: 'Your storage, in motion.'
    // The bar-readout chooser, rendered by the merged Settings page.
    readonly property int modeCount: 6
    readonly property string modeHint: 'Choose what lives beside the chip. One decimal.'
    function modeLabel(index) { return (index+1)+'.  '+Model.modeName(index)+'   \u00b7   '+Model.readout(root.disk,index,root.mountpoint)+(index===4?'  '+Model.modeTag(root.disk,4):'') }
    // What is holding this domain back, ranked worst first. The severity
    // scale is shared across all four domains, so the bar icon and the
    // Constraints page agree on which one is actually the bottleneck.
    readonly property var constraints: Constraints.disk(root.disk, root.mountpoint, root.primary, root.drive, root.stale)
    // The worst row that is actually a constraint, skipping the rows that only
    // describe how the machine is set up.
    readonly property var topConstraint: Constraints.leading(root.constraints)
    readonly property real concern: root.topConstraint ? root.topConstraint.severity : 0
    readonly property string constraintLabel: root.topConstraint ? root.topConstraint.label : 'No constraint'
    readonly property string constraintValue: root.topConstraint ? root.topConstraint.value : '\u2014'
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
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.disk, root.mode, root.mountpoint)
    readonly property string tag: Model.modeTag(root.disk, root.mode)
    property Component barChip: Component { DiskChip {compact:true;body:root.themeBg;glint:root.barForeground;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { DiskChip {width:88;height:88;body:Color.popups.background;glint:root.themeText;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:root.cardLive} }
    property Component cardGraph: Component { DiskHistoryGraph {axesVisible:false;historyData:root.chart;tint:root.tint;writeTint:root.themeAccent;busyTint:root.rampWarn;usedTint:root.themeText;grid:root.stroke;axisText:root.themeMuted;crosshair:root.strokeStrong;hoverBackground:root.surfaceHover;hoverBorder:root.stroke;hoverForeground:root.themeText;fontFamily:root.themeFont} }
""",
}

def brace_block(lines,start):
    depth=0;started=False
    for i in range(start,len(lines)):
        s=re.sub(r'//.*','',lines[i]); s=re.sub(r"'[^']*'",'',s); s=re.sub(r'"[^"]*"','',s)
        for ch in s:
            if ch=='{': depth+=1;started=True
            elif ch=='}':
                depth-=1
                if started and depth==0: return i
    return len(lines)-1

def landmarks(lines):
    L={'components':[]}
    for i,l in enumerate(lines):
        st=l.strip(); flat=st.replace(' ','')
        if st.startswith('WidgetButton {') and 'wb' not in L: L['wb']=i
        if re.match(r'component\s+\w+\s*:',st): L['components'].append((i,brace_block(lines,i),st.split()[1].rstrip(':')))
        if 'id:modeColumn' in flat and 'mode' not in L: L['mode']=i-1 if lines[i-1].strip().endswith('{') else i
        if 'id:mainColumn' in flat and 'main' not in L: L['main']=i-1 if lines[i-1].strip().endswith('{') else i
        if st.startswith('IpcHandler') and 'ipc' not in L: L['ipc']=i
    L['mode']=(L['mode'],brace_block(lines,L['mode']))
    L['main']=(L['main'],brace_block(lines,L['main']))
    L['ipc']=(L['ipc'],brace_block(lines,L['ipc']))
    return L

def main_children(lines,main):
    s,e=main
    # first content line is the one after 'Column {' / 'id:mainColumn'
    first=s+2
    indent=len(lines[s+1])-len(lines[s+1].lstrip())
    kids=[];i=first
    while i<e:
        l=lines[i]
        if l.strip() and (len(l)-len(l.lstrip()))==indent and l.rstrip().endswith('{'):
            j=brace_block(lines,i); kids.append((i,j,l.strip())); i=j+1
        else: i+=1
    return kids,indent

def fix_head(text,key):
    # collapse the two-line settings write into one namespaced call
    text=re.sub(r"\n\s*root\.settings=Object\.assign\(\{\}, root\.settings, \{(\w+):(.*?)\}\)\s*\n\s*if\(root\.bar && root\.bar\.shell\) root\.bar\.shell\.updateEntryInline\(root\.moduleName,root\.settings\)",
                lambda m: "\n        root.setSetting('%s', %s)"%(m.group(1),m.group(2)), text)
    text=re.sub(r'^\s*readonly property real openPanelIndicatorWidth:.*\n','',text,flags=re.M)
    text=re.sub(r'^\s*implicitWidth: button\.implicitWidth\n','',text,flags=re.M)
    text=re.sub(r'^\s*implicitHeight: button\.implicitHeight\n','',text,flags=re.M)
    text=re.sub(r"^\s*moduleName:.*\n",'',text,flags=re.M)
    text=re.sub(r"^\s*ipcTarget:.*\n",'',text,flags=re.M)
    text=re.sub(r"^\s*manageIpc:.*\n",'',text,flags=re.M)
    # Hidden width-floor labels measured the old per-plugin bar readout, whose
    # Text ids went with the bar row. One icon sizes itself, so they are orphans.
    text=re.sub(r'^\s*Text \{ id:(readoutFloor|tagFloor);.*\n','',text,flags=re.M)
    # the merged section owns the sub-tab list (About moved to its own page)
    text=re.sub(r'^\s*readonly property var tabs:.*\n','',text,flags=re.M)
    text=re.sub(r'^\s*readonly property int lastTab:.*\n','',text,flags=re.M)
    # collectors live in their own directory in the merged plugin
    text=text.replace("Qt.resolvedUrl('%s_pulse.py')"%key, "Qt.resolvedUrl('../collectors/%s_pulse.py')"%key)
    return text

for name,sp in SPEC.items():
    src=os.path.join(SRC,sp['pid'],'Panel.qml')
    lines=open(src).read().split('\n')
    L=landmarks(lines)
    kids,indent=main_children(lines,L['main'])
    # tab columns = kids after the header Row; drop the trailing About column and any footer Flow
    tabcols=kids[1:1+len(sp['tabs'])]
    # Everything after the last tab column and before mainColumn's own closing
    # brace: the separator rule, the live status caption and, on Disk, the
    # version footer. Taken as a line range rather than as detected children,
    # because single-line children are invisible to the child scan.
    rest_start=tabcols[-1][1]+1
    # mainColumn's own closing brace, found by indentation. Brace counting is
    # defeated by the regex literals in the footer links, and a two-brace
    # overshoot here silently swallows the popup's closers.
    open_indent=len(lines[L['main'][0]])-len(lines[L['main'][0]].lstrip())
    rest_end=None
    for n in range(rest_start,len(lines)):
        l=lines[n]
        if l.strip()=='}' and (len(l)-len(l.lstrip()))==open_indent:
            rest_end=n-1; break
    if rest_end is None: raise SystemExit('could not find mainColumn close for '+name)

    head='\n'.join(lines[14:L['wb']])
    head=fix_head(head,sp['key'])
    # strip the IpcHandler block if it fell inside head
    ipc_s,ipc_e=L['ipc']
    if ipc_s<L['wb']:
        head='\n'.join([l for n,l in enumerate(lines[14:L['wb']],start=14) if not (ipc_s<=n<=ipc_e)])
        head=fix_head(head,sp['key'])

    # Members declared after the popup block — Net keeps two DNS helpers there
    # — belong to the section root just as much as the ones before it.
    kb=next(n for n,l in enumerate(lines) if l.strip().startswith('KeyboardPanel {'))
    kb_close=next(n for n in range(kb+1,len(lines)) if lines[n].rstrip()=='    }')
    trailing='\n'.join(l for l in lines[kb_close+1:] if l.strip() and l.rstrip()!='}')
    comps='\n'.join('\n'.join(lines[a:b+1]) for a,b,_ in L['components'])
    modecol='\n'.join(lines[L['mode'][0]:L['mode'][1]+1])
    body='\n'.join('\n'.join(lines[a:b+1]) for a,b,_ in tabcols)
    about='\n'.join(lines[rest_start:rest_end+1])

    imports=['import QtQuick']+sp['extra_imports']+['import Quickshell','import Quickshell.Io',
             'import qs.Commons','import qs.Ui','import "../model/%sModel.js" as Model'%name,
             'import "Constraints.js" as Constraints']
    tabs_js='['+','.join("'%s'"%t for t in sp['tabs'])+']'

    out=f'''{chr(10).join(imports)}

// {sp['title']} section of Pulse — the whole of {sp['pid']}'s dashboard, hosted
// inside the merged panel. Everything below the host bridge is the original
// plugin's own code, so nothing it measured or showed is lost in the merge.
Item {{
    id: root

    // ---- host bridge -------------------------------------------------
    // The merged Panel owns the popup, the bar entry and the settings blob.
    // The section reaches those through `host`, and keeps the member names the
    // original code already used, so the ported body needs no rewriting.
    required property var host
    readonly property string prefix: '{sp['key']}'
    readonly property var bar: host.bar
    readonly property color barForeground: host.barForeground
    readonly property bool cardLive: host.opened && host.active === 'overview' && !root.stale && root.setting('animated', true)
    readonly property bool opened: host.opened && host.active === root.prefix
    readonly property var tabs: {tabs_js}
    readonly property int lastTab: root.tabs.length-1
    function setting(key, fallback) {{ return host.setting(root.prefix+'.'+key, fallback) }}
    function setSetting(key, value) {{ host.setSetting(root.prefix+'.'+key, value) }}
    function close() {{ host.close() }}
    function open() {{ host.openSection(root.prefix) }}
    width: parent ? parent.width : 0
    property Item dashboard: null
    implicitHeight: dashboard ? dashboard.implicitHeight : 0

{head}
{trailing}
{SUMMARY[name]}
{comps}

    // The dashboard is the original plugin's whole panel. Building all four of
    // them on every click is what made the merged popup take seconds to appear;
    // tearing them down on close made it take seconds to go. The bar only needs
    // the readings above. This tree is created the first time you open this
    // domain, kept while you stay on it (including through the panel's close
    // fade), and dropped when you leave. (PR #2, jbronssin)
    Repeater {{
        model: (host.active === root.prefix && (host.opened || root.dashboard)) ? 1 : 0
        onItemAdded: function (index, item) {{ root.dashboard = item }}
        onItemRemoved: function (index, item) {{ if (root.dashboard === item) root.dashboard = null }}
        Column {{
        id: mainColumn
        width: root.width
        spacing: 14
        Row {{
            spacing: 8
            Repeater {{
                model: root.tabs
                Action {{
                    required property int index
                    required property string modelData
                    text: modelData
                    selected: root.tab === index
                    onClicked: root.tab = index
                }}
            }}
        }}
{body}
{about}
        }}
    }}
}}
'''
    write_text_atomic(os.path.join(DST,'sections',name+'Section.qml'), out)
    # stash the About/footer leftovers for the merged About page
    write_text_atomic(os.path.join(DST,'sections','_%s_about.qml.part'%sp['key']), about)
    print(f"{name}Section.qml  head={L['wb']-14}L comps={len(L['components'])} tabs={len(tabcols)} footer={rest_end-rest_start+1}L → {len(out.split(chr(10)))}L")

# ---- post-pass fixups, so one run produces buildable files -------------
import glob
for f in glob.glob(os.path.join(DST,'sections','*Section.qml')):
    name=os.path.basename(f).replace('Section.qml','')
    t=open(f).read()
    t=re.sub(r'\bHistoryGraph\b', name+'HistoryGraph', t)
    t=t.replace('"../model/%sModel.js"'%name, '"%sModel.js"'%name)
    t=t.replace("Qt.resolvedUrl('manifest.json')", "Qt.resolvedUrl('../manifest.json')")
    t=t.replace("    readonly property var bar: host.bar",
                "    readonly property string moduleName: host.moduleName\n    readonly property var bar: host.bar")
    write_text_atomic(f, t)
print('fixups applied')


# ---- compact graphs ----------------------------------------------------
# The four history graphs reserve a left/right gutter and a bottom strip for
# axis labels sized for a 139px-tall chart. On the Overview cards they are
# drawn at 106px, where that furniture collides with the trace. `axesVisible`
# turns the labels off and hands the gutters back to the plot, so the card
# shows the same data with none of the scaffolding. It defaults to true, so
# every full-size use is untouched.
GRAPH_AXES = {
    'CpuHistoryGraph': [
        ("            var c=getContext('2d'), w=width-38, h=height-26",
         "            var gutter=root.axesVisible?38:0, foot=root.axesVisible?26:4\n"
         "            var c=getContext('2d'), w=width-gutter, h=height-foot"),
        ("                c.fillStyle=root.axis;c.fillText(String(100-line*25),width,y+3)",
         "                if(root.axesVisible){c.fillStyle=root.axis;c.fillText(String(100-line*25),width,y+3)}"),
        ("            c.fillStyle=root.axis;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',0,height-3)\n"
         "            c.textAlign='right';c.fillText('now',w,height-3)",
         "            if(root.axesVisible){\n"
         "                c.fillStyle=root.axis;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',0,height-3)\n"
         "                c.textAlign='right';c.fillText('now',w,height-3)\n"
         "            }"),
    ],
    'RamHistoryGraph': [
        ("            var c=getContext('2d'), w=width-38, h=height-26",
         "            var gutter=root.axesVisible?38:0, foot=root.axesVisible?26:4\n"
         "            var c=getContext('2d'), w=width-gutter, h=height-foot"),
        ("                c.fillStyle=root.axisText;c.fillText(String(100-line*25)+'%',width,y+3)",
         "                if(root.axesVisible){c.fillStyle=root.axisText;c.fillText(String(100-line*25)+'%',width,y+3)}"),
        ("            c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',0,height-3)\n"
         "            c.textAlign='right';c.fillText('now',w,height-3)",
         "            if(root.axesVisible){\n"
         "                c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',0,height-3)\n"
         "                c.textAlign='right';c.fillText('now',w,height-3)\n"
         "            }"),
    ],
    'NetHistoryGraph': [
        ("    readonly property int leftAxis: 52", "    readonly property int leftAxis: axesVisible ? 52 : 0"),
        ("    readonly property int rightAxis: 40", "    readonly property int rightAxis: axesVisible ? 40 : 0"),
        ("            var c=getContext('2d'), w=root.plotWidth(), h=height-26, x0=root.leftAxis",
         "            var c=getContext('2d'), w=root.plotWidth(), h=height-(root.axesVisible?26:4), x0=root.leftAxis"),
        ("                c.fillStyle=root.axisText;c.textAlign='right';c.fillText(Model.shortRate(root.ceiling*(1-line/4))+'/s',x0-4,y+3)\n"
         "                c.fillStyle=root.latencyTint;c.textAlign='left';c.fillText(Math.round(root.msCeiling*(1-line/4))+'ms',x0+w+4,y+3)",
         "                if(root.axesVisible){\n"
         "                    c.fillStyle=root.axisText;c.textAlign='right';c.fillText(Model.shortRate(root.ceiling*(1-line/4))+'/s',x0-4,y+3)\n"
         "                    c.fillStyle=root.latencyTint;c.textAlign='left';c.fillText(Math.round(root.msCeiling*(1-line/4))+'ms',x0+w+4,y+3)\n"
         "                }"),
        ("            c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',x0,height-3)\n"
         "            c.textAlign='right';c.fillText('now',x0+w,height-3)",
         "            if(root.axesVisible){\n"
         "                c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',x0,height-3)\n"
         "                c.textAlign='right';c.fillText('now',x0+w,height-3)\n"
         "            }"),
    ],
    'DiskHistoryGraph': [
        ("    readonly property int leftAxis: 46", "    readonly property int leftAxis: axesVisible ? 46 : 0"),
        ("    readonly property int rightAxis: 34", "    readonly property int rightAxis: axesVisible ? 34 : 0"),
        ("            var c=getContext('2d'), w=root.plotWidth(), h=height-26, x0=root.leftAxis",
         "            var c=getContext('2d'), w=root.plotWidth(), h=height-(root.axesVisible?26:4), x0=root.leftAxis"),
        ("                c.fillStyle=root.axisText;c.textAlign='right';c.fillText(Model.shortRate(root.ceiling*(1-line/4))+'/s',x0-4,y+3)\n"
         "                c.textAlign='left';c.fillText(String(100-line*25)+'%',x0+w+4,y+3)",
         "                if(root.axesVisible){\n"
         "                    c.fillStyle=root.axisText;c.textAlign='right';c.fillText(Model.shortRate(root.ceiling*(1-line/4))+'/s',x0-4,y+3)\n"
         "                    c.textAlign='left';c.fillText(String(100-line*25)+'%',x0+w+4,y+3)\n"
         "                }"),
        ("            c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',x0,height-3)\n"
         "            c.textAlign='right';c.fillText('now',x0+w,height-3)",
         "            if(root.axesVisible){\n"
         "                c.fillStyle=root.axisText;c.textAlign='left';c.fillText(root.historyData.seconds===3600?'1 hour ago':root.historyData.seconds===86400?'24 hours ago':'7 days ago',x0,height-3)\n"
         "                c.textAlign='right';c.fillText('now',x0+w,height-3)\n"
         "            }"),
    ],
}
# Chips, graphs and domain models are copied fresh from the installed plugins
# on every run, so this script is idempotent and re-running it picks up any
# upstream change rather than patching an already-patched file.
ASSETS = [
    ('nixfred.cpu-pulse',  'CpuChip.qml',      'CpuChip.qml'),
    ('nixfred.cpu-pulse',  'HistoryGraph.qml', 'CpuHistoryGraph.qml'),
    ('nixfred.cpu-pulse',  'Model.js',         'CpuModel.js'),
    ('nixfred.ram-pulse',  'MemoryChip.qml',   'MemoryChip.qml'),
    ('nixfred.ram-pulse',  'HistoryGraph.qml', 'RamHistoryGraph.qml'),
    ('nixfred.ram-pulse',  'Model.js',         'RamModel.js'),
    ('nixfred.net-pulse',  'NetChip.qml',      'NetChip.qml'),
    ('nixfred.net-pulse',  'UsageGraph.qml',   'UsageGraph.qml'),
    ('nixfred.net-pulse',  'HistoryGraph.qml', 'NetHistoryGraph.qml'),
    ('nixfred.net-pulse',  'Model.js',         'NetModel.js'),
    ('nixfred.disk-pulse', 'DiskChip.qml',     'DiskChip.qml'),
    ('nixfred.disk-pulse', 'HistoryGraph.qml', 'DiskHistoryGraph.qml'),
    ('nixfred.disk-pulse', 'Model.js',         'DiskModel.js'),
]
import shutil as _sh
for pid, src_name, dst_name in ASSETS:
    _sh.copyfile(os.path.join(SRC, pid, src_name), os.path.join(DST, 'sections', dst_name))
print('assets refreshed from upstream plugins')

for stem, edits in GRAPH_AXES.items():
    f = os.path.join(DST, 'sections', stem + '.qml')
    t = open(f).read()
    for old, new in edits:
        if old not in t:
            raise SystemExit('axis patch missed in %s:\n%s' % (stem, old[:90]))
        t = t.replace(old, new, 1)
    anchor = '    property var historyData'
    t = t.replace(anchor,
                  '    // False drops the axis labels and their gutters, for the Overview\n'
                  '    // cards where the chart is too short to carry them.\n'
                  '    property bool axesVisible: true\n' + anchor, 1)
    t = t.replace('        onWidthChanged: root.repaint()',
                  '        onWidthChanged: root.repaint()\n'
                  '        Connections { target: root; function onAxesVisibleChanged() { root.repaint() } }', 1)
    write_text_atomic(f, t)
print('graph axes made optional')

# Chips and graphs each import their own domain model by name, so the four
# copies can share one directory without one shadowing another.
OWNER={'CpuChip':'Cpu','CpuHistoryGraph':'Cpu','MemoryChip':'Ram','RamHistoryGraph':'Ram',
       'NetChip':'Net','NetHistoryGraph':'Net','UsageGraph':'Net',
       'DiskChip':'Disk','DiskHistoryGraph':'Disk'}
for stem,dom in OWNER.items():
    f=os.path.join(DST,'sections',stem+'.qml')
    if not os.path.exists(f): continue
    t=open(f).read()
    t=t.replace('import "Model.js" as Model','import "%sModel.js" as Model'%dom)
    write_text_atomic(f, t)
print('chip model imports repointed')

# ---- fixes carried on top of the upstream models --------------------------
# DiskModel.js is refreshed from the installed Disk Pulse plugin above, so a
# fix made to the copy in sections/ would be silently reverted by the next run.
# Each patch here is re-applied after the refresh, and is skipped rather than
# failed when upstream has already taken the same change.
MODEL_PATCHES = {
    'DiskModel.js': [
        # Issue #1: PSI io counts io_uring event loops that never touch a disk,
        # so "stalling" requires the drive to agree.
        ("    if (psi >= 10) return 'STORAGE IS STALLING'",
         "    // PSI io also counts io_uring event loops that never touch a disk (issue\n"
         "    // #1), so the verdict only says stalling when the drive agrees.\n"
         "    var drain = drive && drive.rates ? Math.max(num(drive.rates.awaitRead), num(drive.rates.awaitWrite)) : 0\n"
         "    var queue = drive && drive.rates ? num(drive.rates.queue) : 0\n"
         "    var driveAgrees = !drive || !drive.rates || util >= 20 || drain >= 10 || queue >= 1\n"
         "    if (psi >= 10 && driveAgrees) return 'STORAGE IS STALLING'"),
    ],
}
# The four chips paint a 12px shadowBlur on the GUI thread: 30-70 ms per paint
# at Overview-card size, ten paints a second each, which stalled the panel as
# it opened. Replaced with a few widening, fading strokes that cost ~1 ms.
CHIP_GLOW_OLD = ("            c.shadowColor=root.tint; c.shadowBlur=root.compact?5:12\n"
                 "            c.strokeRect(x,y,body,body); c.shadowBlur=0")
CHIP_GLOW_NEW = ("            // Glow as a few widening, fading strokes, not shadowBlur. The blur is\n"
                 "            // rasterised on the GUI thread and cost 30-70 ms per paint at card size,\n"
                 "            // at ten paints a second per chip, which is what made the panel hesitate\n"
                 "            // as it opened. These strokes cost about a millisecond.\n"
                 "            var haloBase=c.lineWidth\n"
                 "            c.save(); c.strokeStyle=root.tint\n"
                 "            for(var halo=(root.compact?2:4); halo>0; halo--){ c.globalAlpha=0.09; c.lineWidth=haloBase+halo*(root.compact?1.2:2.4); c.strokeRect(x,y,body,body) }\n"
                 "            c.restore()\n"
                 "            c.strokeRect(x,y,body,body)")
for chip in ('CpuChip.qml', 'DiskChip.qml', 'NetChip.qml', 'MemoryChip.qml'):
    MODEL_PATCHES[chip] = [(CHIP_GLOW_OLD, CHIP_GLOW_NEW)]

# ---- no fixed page may scroll ---------------------------------------------
# On a 1000 px-tall screen the stacked originals ran past the bottom. The panel
# is 1240 px wide; these patches let the paged and gridded content use that
# width instead of height. Nothing is removed. Open-ended lists may still
# scroll, which is fine; a page of fixed layout may not.
LAYOUT_PATCHES = {
    'NetSection.qml': [
        # Wi-Fi: the eight networks on a page sit in two columns of four.
        ("                    Repeater {\n                        model:root.wifiRows.slice(root.wifiPage*8,root.wifiPage*8+8)",
         "                    Flow{width:parent.width;spacing:12\n                    Repeater {\n                        model:root.wifiRows.slice(root.wifiPage*8,root.wifiPage*8+8)"),
        ("width:mainColumn.width;height:prompting?92:58", "width:(mainColumn.width-12)/2;height:prompting?92:58"),
        ("                    Row{spacing:10;visible:root.wifiRows.length>8",
         "                    } // end of the two-column Wi-Fi Flow\n                    Row{spacing:10;visible:root.wifiRows.length>8"),
    ],
    'CpuSection.qml': [
        # Every thread: as many columns as the card has room for (24 threads fit
        # in two rows at 1240 px instead of four at six columns).
        ("Grid{width:parent.width;columns:Math.max(1,Math.min(6,root.cores.length));",
         "Grid{id:threadGrid;width:parent.width;columns:Math.max(1,Math.min(Math.max(6,Math.floor((coreColumn.width+8)/96)),root.cores.length));"),
        ("width:(coreColumn.width-8*5)/6;spacing:4",
         "width:(coreColumn.width-8*(threadGrid.columns-1))/threadGrid.columns;spacing:4"),
    ],
    'DiskSection.qml': [
        # Storage lab: the stat tiles spread to the width they are given.
        ("    readonly property string prefix: 'disk'\n",
         "    readonly property string prefix: 'disk'\n"
         "    // Storage-lab tiles spread to the width they are given, so a wide panel\n"
         "    // shows the same tiles in fewer rows instead of pushing past the screen.\n"
         "    readonly property int labColumns: Math.max(4, Math.floor((root.width + 10) / 200))\n"),
        ("Grid{width:parent.width;columns:4;spacing:10;visible:root.drive!==null",
         "Grid{width:parent.width;columns:root.labColumns;spacing:10;visible:root.drive!==null"),
        ("Grid{width:parent.width;columns:4;spacing:10;visible:root.pool!==null",
         "Grid{width:parent.width;columns:root.labColumns;spacing:10;visible:root.pool!==null"),
        ("Grid{width:parent.width;columns:4;spacing:10\n",
         "Grid{width:parent.width;columns:root.labColumns;spacing:10\n"),
        ("width:(mainColumn.width-30)/4;height:80;valueSize:17",
         "width:(mainColumn.width-10*(root.labColumns-1))/root.labColumns;height:80;valueSize:17", 'all'),
    ],
}
LAYOUT_PATCHES_2 = {'NetSection.qml': [('                    Repeater{\n                        model:root.net.interfaces||[]', '                    Flow{width:parent.width;spacing:12 // interfaces: two columns of cards\n                    Repeater{\n                        model:root.net.interfaces||[]'), ('width:mainColumn.width;height:col.implicitHeight+28;radius:14;color:modelData.active', 'width:(mainColumn.width-12)/2;height:col.implicitHeight+28;radius:14;color:modelData.active'), ("                                Grid{width:parent.width;columns:4;spacing:8\n                                    Stat{width:(parent.width-24)/4;height:66;label:'IPv4'", "                                Grid{id:ifaceGrid;width:parent.width;columns:2;spacing:8\n                                    Stat{width:(parent.width-24)/4;height:66;label:'IPv4'"), ('Stat{width:(parent.width-24)/4;height:66;', 'Stat{width:(parent.width-8)/2;height:66;', 'all'), ("                                Row{spacing:8\n                                    Action{visible:card.actionUuid!==''&&!card.external", "                                Flow{width:parent.width;spacing:8\n                                    Action{visible:card.actionUuid!==''&&!card.external")], 'RamSection.qml': [('width:parent.width;spacing:10;visible:root.tab===1;height:visible?implicitHeight:0', 'width:parent.width;spacing:6;visible:root.tab===1;height:visible?implicitHeight:0 // tight: fits a 1000 px screen')], 'DiskSection.qml': [('width:parent.width;spacing:10;visible:root.tab===1;height:visible?implicitHeight:0', 'width:parent.width;spacing:6;visible:root.tab===1;height:visible?implicitHeight:0 // tight: fits a 1000 px screen'), ('width:parent.width;spacing:14;visible:root.tab===0\n', 'width:parent.width;spacing:10;visible:root.tab===0 // tight: fits a 1000 px screen\n'), ('Stat{width:(parent.width-30)/4;height:96;', 'Stat{width:(parent.width-30)/4;height:90;', 'all'), ('Rectangle {width:parent.width;height:242;radius:14;color:root.surface;border.color:root.stroke\n                        Column {anchors.fill:parent;anchors.margins:14;spacing:9', 'Rectangle {width:parent.width;height:214;radius:14;color:root.surface;border.color:root.stroke\n                        Column {anchors.fill:parent;anchors.margins:14;spacing:9'), ('DiskHistoryGraph{width:parent.width;height:139;', 'DiskHistoryGraph{width:parent.width;height:111;')]}
for fname, edits in LAYOUT_PATCHES_2.items():
    LAYOUT_PATCHES.setdefault(fname, []).extend(edits)
LAYOUT_PATCHES['NetSection.qml'].append(("                    }\n                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Click any address to copy", "                    }\n                    } // end of the two-column interfaces Flow\n                    Label{width:parent.width;wrapMode:Text.WordWrap;text:'Click any address to copy"))
# labels inside the interface action Flow cannot use anchors
# interface action labels cannot use anchors inside a Flow; three card columns
LAYOUT_PATCHES['NetSection.qml'].extend([("                                    Label{visible:card.actionUuid==='';text:card.external?'Managed outside NetworkManager ('+card.modelData.nm.state+')':card.profiles.length===0&&card.modelData.kind!=='virtual'?'No saved profile for this device':'Not managed by NetworkManager';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}", "                                    Label{visible:card.actionUuid==='';text:card.external?'Managed outside NetworkManager ('+card.modelData.nm.state+')':card.profiles.length===0&&card.modelData.kind!=='virtual'?'No saved profile for this device':'Not managed by NetworkManager';font.pixelSize:10;height:28;verticalAlignment:Text.AlignVCenter}"), ("                                    Label{visible:!card.managed&&card.actionUuid!=='';text:'saved profile · not active';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}", "                                    Label{visible:!card.managed&&card.actionUuid!=='';text:'saved profile · not active';font.pixelSize:10;height:28;verticalAlignment:Text.AlignVCenter}"), ("                                    Label{visible:card.managed&&card.modelData.kind==='wifi'&&card.connected;text:'Wi-Fi disconnects live on the Wi-Fi tab';font.pixelSize:10;anchors.verticalCenter:parent.verticalCenter}", "                                    Label{visible:card.managed&&card.modelData.kind==='wifi'&&card.connected;text:'Wi-Fi disconnects live on the Wi-Fi tab';font.pixelSize:10;height:28;verticalAlignment:Text.AlignVCenter}"), ('width:(mainColumn.width-12)/2;height:col.implicitHeight+28;radius:14', 'width:(mainColumn.width-24)/3;height:col.implicitHeight+28;radius:14', 'all')])
# Columns from the width actually available, so a wide screen gets more columns
# rather than more rows. Fixed counts pushed seven interface cards into three
# tall rows on a 5120 px ultrawide.
LAYOUT_PATCHES['NetSection.qml'].extend([
    ("    readonly property string stateDir: (Quickshell.env('XDG_STATE_HOME')",
     "    readonly property int ifaceColumns: Math.max(2, Math.min(6, Math.floor((root.width + 12) / 400)))\n"
     "    readonly property int wifiColumns: Math.max(2, Math.min(4, Math.floor((root.width + 12) / 620)))\n"
     "    readonly property string stateDir: (Quickshell.env('XDG_STATE_HOME')"),
    ("width:(mainColumn.width-12)/2;height:prompting?92:58",
     "width:(mainColumn.width-12*(root.wifiColumns-1))/root.wifiColumns;height:prompting?92:58"),
    ("width:(mainColumn.width-24)/3;height:col.implicitHeight+28;radius:14",
     "width:(mainColumn.width-12*(root.ifaceColumns-1))/root.ifaceColumns;height:col.implicitHeight+28;radius:14"),
])
for fname, edits in LAYOUT_PATCHES.items():
    MODEL_PATCHES.setdefault(fname, []).extend(edits)
for fname, edits in MODEL_PATCHES.items():
    f = os.path.join(DST, 'sections', fname)
    t = open(f).read()
    for edit in edits:
        old, new = edit[0], edit[1]
        every = len(edit) > 2 and edit[2] == 'all'
        if new in t:
            continue
        if old not in t:
            raise SystemExit('model patch no longer applies to %s:\n%s' % (fname, old))
        t = t.replace(old, new) if every else t.replace(old, new, 1)
    write_text_atomic(f, t)
print('model patches applied')
