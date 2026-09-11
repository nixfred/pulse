import re,os,sys
SRC=os.path.expanduser('~/.config/omarchy/plugins/')
DST=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))+'/'

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
    readonly property real concern: root.stale ? 1 : Math.max(0, Math.min(1, (root.cpu.busyPct || 0)/100))
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.cpu, root.mode)
    readonly property string tag: Model.modeTag(root.mode)
    property Component barChip: Component { CpuChip {compact:true;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.background;glint:root.bar?root.bar.foreground:root.ink;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { CpuChip {width:88;height:88;busy:root.cpu.busyPct || 0;cores:root.coreLoads;tint:root.tint;stops:root.rampStops;dieFill:Color.popups.background;glint:root.ink;animate:root.cardLive} }
    property Component cardGraph: Component { CpuHistoryGraph {historyData:root.chart;tint:root.tint;heat:root.heat;ink:root.ink;surface:Color.popups.background} }
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
    readonly property real concern: root.stale ? 1 : Math.max(0, Math.min(1, 1 - (root.mem.availablePct || 0)/100))
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.mem, root.mode)
    readonly property string tag: root.mode===1||root.mode===2 ? 'USED' : 'AVAILABLE'
    property Component barChip: Component { MemoryChip {compact:true;body:root.themeBg;available:root.mem.availablePct || 0;tint:root.tint;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { MemoryChip {width:88;height:88;body:Color.popups.background;available:root.mem.availablePct || 0;tint:root.tint;animate:root.cardLive} }
    property Component cardGraph: Component { RamHistoryGraph {historyData:root.chart;tint:root.tint;swapTint:root.themeAccent;grid:root.stroke;axisText:root.themeMuted;crosshair:root.strokeStrong;hoverBackground:root.surfaceHover;hoverBorder:root.stroke;hoverForeground:root.themeText;fontFamily:root.themeFont} }
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
    readonly property real concern: root.stale ? 1 : Math.max(0, Math.min(1, 1 - (root.health || 0)/100))
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.net, root.mode)
    readonly property string tag: Model.modeTag(root.net, root.mode)
    property Component barChip: Component { NetChip {compact:true;body:Color.bar.background;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint;stops:root.rampStops;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { NetChip {width:88;height:88;body:Color.popups.background;kind:root.chipKind;level:root.health/100;activity:root.activity;tint:root.tint;stops:root.rampStops;animate:root.cardLive} }
    property Component cardGraph: Component { NetHistoryGraph {historyData:root.chart;tint:root.tint;latencyTint:root.themeUrgent;upTint:root.themeAccent;axisText:root.dimText;gridLine:root.gridLine;tipBackground:Color.tooltip.background;tipBorder:Color.tooltip.border;tipText:Color.tooltip.text} }
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
    readonly property real concern: root.stale ? 1 : Math.max(0, Math.min(1, 1 - (root.chipFree || 0)/100))
    readonly property string headline: root.stale ? '\u2014' : Model.readout(root.disk, root.mode, root.mountpoint)
    readonly property string tag: Model.modeTag(root.disk, root.mode)
    property Component barChip: Component { DiskChip {compact:true;body:root.themeBg;glint:root.barForeground;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:!root.stale && root.setting('animated',true)} }
    property Component cardChip: Component { DiskChip {width:88;height:88;body:Color.popups.background;glint:root.themeText;free:root.chipFree;activity:root.activity;reading:root.reading;writing:root.writing;tint:root.tint;animate:root.cardLive} }
    property Component cardGraph: Component { DiskHistoryGraph {historyData:root.chart;tint:root.tint;writeTint:root.themeAccent;busyTint:root.rampWarn;usedTint:root.themeText;grid:root.stroke;axisText:root.themeMuted;crosshair:root.strokeStrong;hoverBackground:root.surfaceHover;hoverBorder:root.stroke;hoverForeground:root.themeText;fontFamily:root.themeFont} }
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
             'import qs.Commons','import qs.Ui','import "../model/%sModel.js" as Model'%name]
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
    implicitHeight: mainColumn.implicitHeight

{head}
{trailing}
{SUMMARY[name]}
{comps}

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
'''
    open(os.path.join(DST,'sections',name+'Section.qml'),'w').write(out)
    # stash the About/footer leftovers for the merged About page
    open(os.path.join(DST,'sections','_%s_about.qml.part'%sp['key']),'w').write(about)
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
    open(f,'w').write(t)
print('fixups applied')

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
    open(f,'w').write(t)
print('chip model imports repointed')
