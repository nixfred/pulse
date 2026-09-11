import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "sections"
import "Model.js" as Model

// Pulse — one plugin for CPU, RAM, Disk and Network.
//
// The four Pulse plugins each grew the same shape: a chip in the bar, a popup
// with an Overview, a hogs table, a lab of raw numbers and an About. Four
// widgets meant four bar entries competing for width and four popups to open
// before you knew what the machine was doing. This merges them without giving
// anything up: the top page answers "how is the machine" in one glance, and
// each domain keeps its entire original dashboard behind its own name.
//
// Nothing was summarised away. sections/*Section.qml hold the original panels'
// own code; this file only owns the bar row, the page switcher and the two new
// pages (Overview and Settings) that only exist because the four are together.
Panel {
    id: root
    moduleName: 'nixfred.pulse'
    ipcTarget: 'nixfred.pulse'
    manageIpc: false
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // The page on screen. 'overview' is the summary of all four; the four
    // domain keys each show that plugin's whole dashboard; settings and about
    // are the merged pages.
    property string active: 'overview'
    property bool chooseMode: false
    property string actionStatus: ''
    readonly property var pages: [
        {key: 'overview',    label: 'Overview'},
        {key: 'constraints', label: 'Constraints'},
        {key: 'cpu',      label: 'CPU'},
        {key: 'ram',      label: 'RAM'},
        {key: 'disk',     label: 'Disk'},
        {key: 'net',      label: 'Network'},
        {key: 'settings', label: 'Settings'},
        {key: 'about',    label: 'About'}
    ]
    readonly property var domains: [cpuSection, ramSection, diskSection, netSection]
    readonly property var domainKeys: ['cpu', 'ram', 'disk', 'net']

    // Theme roles. One decision — the popup text colour — drives the whole
    // surface, exactly as each of the four plugins did on its own, so the
    // merged chrome sits in the same visual language as the ported bodies.
    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)
    readonly property color rule: Util.alpha(ink, 0.14)

    readonly property int pageIndex: {
        for (var i = 0; i < root.pages.length; i++)
            if (root.pages[i].key === root.active) return i
        return 0
    }
    // The domain with the least headroom. Each section scores itself 0..1 in
    // its own terms — busy for the CPU, missing headroom for RAM and disk,
    // lost signal for the network — and offline always scores 1, because a
    // recorder that stopped is the most important thing on the panel.
    readonly property var worst: {
        var pick = null
        for (var i = 0; i < root.domains.length; i++) {
            var d = root.domains[i]
            if (!d) continue
            if (!pick || d.concern > pick.concern) pick = d
        }
        return pick
    }

    // What the single bar icon shows. 'auto' is the default and the point of
    // the merge: the icon becomes whichever domain is currently the biggest
    // constraint, and says so. Anything else is a pin the user chose from the
    // right-click chooser, and it stays put.
    readonly property string barSource: String(root.setting('barSource', 'auto'))
    readonly property bool barAuto: root.barSource === 'auto'
    // Auto follows `worst`, but not instantly. Two domains sitting a hair
    // apart would otherwise trade the icon back and forth every few seconds,
    // which reads as a fault rather than as information. The leader has to be
    // clearly ahead to take it — except when a recorder goes offline, which
    // always wins, because that is the one thing you must not miss.
    readonly property real switchMargin: 0.08
    property string autoKey: ''
    readonly property var autoDomain: root.sectionFor(root.autoKey) || root.worst
    function refreshAutoKey() {
        var leader = root.worst
        if (!leader) return
        var current = root.sectionFor(root.autoKey)
        if (!current || leader === current) { root.autoKey = leader.prefix; return }
        if (leader.stale && !current.stale) { root.autoKey = leader.prefix; return }
        if (leader.concern > current.concern + root.switchMargin) root.autoKey = leader.prefix
    }
    Component.onCompleted: root.refreshAutoKey()
    Timer { interval: 2000; running: true; repeat: true; onTriggered: root.refreshAutoKey() }

    readonly property var barDomain: root.barAuto ? root.autoDomain : (root.sectionFor(root.barSource) || root.autoDomain)
    readonly property string barKey: root.barDomain ? root.barDomain.prefix : 'cpu'
    // In auto mode the second line names the constraint, because the whole
    // promise is that you can tell what changed without opening anything. When
    // pinned it names the readout, because then you already know the domain.
    readonly property string barCaption: {
        if (!root.barDomain) return 'WAITING FOR TELEMETRY'
        if (root.barDomain.stale) return root.barDomain.sectionTitle.toUpperCase() + ' · OFFLINE'
        if (root.barAuto) return root.barDomain.sectionTitle.toUpperCase() + ' · ' + root.barDomain.constraintLabel.toUpperCase()
        return root.barDomain.sectionTitle.toUpperCase() + ' · ' + root.barDomain.tag
    }
    function pinBar(key, mode) {
        root.setSetting('barSource', key)
        if (key !== 'auto') {
            var s = root.sectionFor(key)
            if (s && mode !== undefined && mode !== null) s.setMode(mode)
        }
    }
    function setSetting(key, value) {
        var next = {}
        for (var k in root.settings) next[k] = root.settings[k]
        next[key] = value
        root.settings = next
        if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    }
    function openSection(key) { root.chooseMode = false; root.active = key; root.open() }
    function showPage(key) { root.active = key }
    function status() {
        return JSON.stringify({
            opened: root.opened, active: root.active, version: root.version,
            chooseMode: root.chooseMode, barSource: root.barSource, barKey: root.barKey,
            barCaption: root.barCaption,
            // Content geometry, so a caller can crop a screenshot to the panel
            // without guessing where it ends.
            panelWidth: panel.contentWidth, panelHeight: panel.contentHeight,
            cpu: cpuSection.status ? JSON.parse(cpuSection.status()) : null,
            ram: ramSection.status ? JSON.parse(ramSection.status()) : null,
            disk: diskSection.status ? JSON.parse(diskSection.status()) : null,
            net: netSection.status ? JSON.parse(netSection.status()) : null
        })
    }

    property string version: ''
    FileView {
        id: manifestFile
        path: String(Qt.resolvedUrl('manifest.json')).replace(/^file:\/\//, '')
        printErrors: false
        onLoaded: { try { root.version = String(JSON.parse(text()).version || '') } catch (e) {} }
    }

    IpcHandler {
        target: 'nixfred.pulse'
        function open(): void { root.chooseMode = false; root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.chooseMode = false; root.toggle() }
        function status(): string { return root.status() }
        function modes(): void { root.chooseMode = true; root.open() }
        function settings(): void { root.chooseMode = false; root.active = 'settings'; root.open() }
        function constraints(): void { root.chooseMode = false; root.active = 'constraints'; root.open() }
        // Put the icon back on auto, or pin it, without opening the panel.
        function pin(page: string): void { root.pinBar(String(page || 'auto'), null) }
        // Jump straight to one domain's dashboard — the replacement for the
        // four plugins' separate `open` calls.
        function show(page: string): void { root.openSection(String(page || 'overview')) }
        function showTab(page: string, value: int): void {
            root.openSection(String(page || 'overview'))
            var s = root.sectionFor(String(page || ''))
            if (s) s.tab = Model.clamp(value, 0, s.lastTab)
        }
        function display(page: string, value: int): void {
            var s = root.sectionFor(String(page || ''))
            if (s) s.setMode(value)
        }
        function historyRange(page: string, value: int): void {
            var s = root.sectionFor(String(page || ''))
            if (s && [3600, 86400, 604800].indexOf(value) >= 0) s.range = value
        }
    }
    function sectionFor(key) {
        var i = root.domainKeys.indexOf(key)
        return i < 0 ? null : root.domains[i]
    }

    // ---- bar entry ---------------------------------------------------
    // ONE icon. That is the whole point of the merge: not four chips sharing a
    // button, but a single readout that is always showing you the thing that
    // matters most right now. The chip itself is the constrained domain's own
    // chip, so the shape and colour change with it, and the caption underneath
    // names the domain and what is constraining it.
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        labelVisible: false
        hasVisualContent: true
        fixedWidth: vertical ? -1 : barRow.implicitWidth + 12
        tooltipText: {
            var lines = [root.barAuto ? 'Pulse · following the biggest constraint'
                                      : 'Pulse · pinned to ' + (root.barDomain ? root.barDomain.sectionTitle : root.barSource)]
            for (var i = 0; i < root.domains.length; i++) {
                var d = root.domains[i]
                if (!d) continue
                lines.push((d === root.barDomain ? '▸ ' : '  ') + d.sectionTitle + ': '
                           + (d.stale ? 'telemetry offline'
                                      : d.headline + ' ' + d.tag + '  —  ' + d.constraintLabel + ' ' + d.constraintValue))
            }
            lines.push('Left-click: dashboard · Right-click: choose the readout')
            return lines.join('\n')
        }
        onPressed: function (b) {
            if (b === Qt.RightButton) { root.chooseMode = true; root.open() }
            else { root.chooseMode = false; root.active = 'overview'; root.toggle() }
        }
        Row {
            id: barRow
            anchors.centerIn: parent
            spacing: 5
            Item {
                width: chipLoader.implicitWidth
                height: chipLoader.implicitHeight
                anchors.verticalCenter: parent.verticalCenter
                Loader {
                    id: chipLoader
                    anchors.centerIn: parent
                    // Keyed on the domain so the chip is rebuilt when the icon
                    // switches, rather than a stale one being re-bound.
                    sourceComponent: root.barDomain ? root.barDomain.barChip : null
                }
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                Text {
                    text: root.barDomain ? root.barDomain.headline : '—'
                    color: root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: 12
                    font.bold: true
                    textFormat: Text.PlainText
                }
                Text {
                    text: root.barCaption
                    color: root.barDomain ? root.barDomain.tint : root.barForeground
                    font.pixelSize: 7
                    font.letterSpacing: 0.6
                    font.bold: true
                    textFormat: Text.PlainText
                }
            }
        }
    }

    component Label: Text {
        color: root.inkDim
        font.pixelSize: 12
        textFormat: Text.PlainText
    }
    component Heading: Text {
        color: root.ink
        font.pixelSize: 15
        font.bold: true
        textFormat: Text.PlainText
    }
    component Action: Rectangle {
        id: act
        property string text: ''
        property bool selected: false
        property color accent: root.ink
        signal clicked()
        implicitWidth: caption.implicitWidth + 26
        implicitHeight: 34
        radius: 9
        color: act.selected ? Qt.alpha(accent, Style.selectedFillAlpha) : area.containsMouse ? Style.hoverFill : Style.normalFill
        border.color: act.selected ? accent : area.containsMouse ? Style.hoverBorderColor : Style.normalBorderColor
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            id: caption
            anchors.centerIn: parent
            text: act.text
            color: act.selected ? root.ink : root.inkDim
            font.pixelSize: 12
            font.bold: act.selected
            textFormat: Text.PlainText
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: act.clicked()
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: body
        // Both dimensions are handed the content's real size. KeyboardPanel
        // fits them to the screen itself (bar and margins already subtracted),
        // and pre-clamping here is what makes a panel scroll while the screen
        // still has room.
        contentWidth: panel.fittedContentWidth(980)
        contentHeight: panel.fittedContentHeight(shell.implicitHeight)
        Item {
            id: body
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: { if (root.chooseMode) root.chooseMode = false; else root.close() }
            Keys.onPressed: function (event) {
                if (root.chooseMode) return
                if (event.key === Qt.Key_Left) {
                    root.active = root.pages[Math.max(0, root.pageIndex - 1)].key
                    event.accepted = true
                }
                if (event.key === Qt.Key_Right) {
                    root.active = root.pages[Math.min(root.pages.length - 1, root.pageIndex + 1)].key
                    event.accepted = true
                }
            }
            Rectangle { anchors.fill: parent; anchors.margins: -10; radius: 14; color: Color.popups.background }

            Flickable {
                id: scroller
                anchors.fill: parent
                clip: true
                interactive: contentHeight > height
                contentWidth: width
                contentHeight: shell.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 6000
                maximumFlickVelocity: 2600
                ScrollBar.vertical: ScrollBar {
                    policy: scroller.contentHeight > scroller.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    width: 6
                }
                onVisibleChanged: if (!visible) contentY = 0

                Column {
                    id: shell
                    width: scroller.width - (scroller.contentHeight > scroller.height ? 10 : 0)
                    spacing: 14

                    // Header: the product name, and the verdict of whichever
                    // page you are on. On Overview that is the machine's worst
                    // reading, which is the one you came to find.
                    Row {
                        width: parent.width
                        spacing: 10
                        Column {
                            width: parent.width - 290
                            spacing: 3
                            Heading {
                                text: {
                                    if (root.chooseMode) return 'PULSE'
                                    var s = root.sectionFor(root.active)
                                    return s ? s.sectionTitle.toUpperCase() + ' PULSE' : 'PULSE'
                                }
                                font.pixelSize: 19
                                font.letterSpacing: 3
                            }
                            Label {
                                text: {
                                    var tail = root.version !== '' ? '   ·   v' + root.version : ''
                                    if (root.chooseMode) return 'Choose what the bar icon shows.' + tail
                                    var s = root.sectionFor(root.active)
                                    return (s ? s.sectionBlurb : 'CPU, memory, storage and network in one place.') + tail
                                }
                                font.pixelSize: 11
                            }
                        }
                        Rectangle {
                            id: verdictPill
                            width: 280
                            height: 32
                            radius: 16
                            // On a domain page the pill speaks for that domain.
                            // On Overview, Settings or About it speaks for the
                            // unhappiest domain, which is the reading you most
                            // need to see without choosing a page first.
                            readonly property var subject: root.chooseMode ? root.worst : (root.sectionFor(root.active) || root.worst)
                            readonly property color subjectTint: subject ? subject.tint : root.ink
                            color: Qt.alpha(subjectTint, 0.14)
                            border.color: Qt.alpha(subjectTint, 0.5)
                            Row {
                                anchors.centerIn: parent
                                spacing: 7
                                Rectangle {
                                    width: 6; height: 6; radius: 3
                                    color: verdictPill.subjectTint
                                    anchors.verticalCenter: parent.verticalCenter
                                    SequentialAnimation on opacity {
                                        running: root.opened && !!verdictPill.subject && !verdictPill.subject.stale
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 0.3; duration: 900 }
                                        NumberAnimation { to: 1; duration: 900 }
                                    }
                                }
                                Label {
                                    // On a domain page this is that domain's own
                                    // phrase. Everywhere else it names the actual
                                    // constraint, so the pill can never say
                                    // "cruising" while Constraints says critical.
                                    text: {
                                        if (!verdictPill.subject) return 'WAITING FOR TELEMETRY'
                                        if (root.sectionFor(root.active) && !root.chooseMode) return verdictPill.subject.verdict
                                        return verdictPill.subject.sectionTitle.toUpperCase() + ' · ' + verdictPill.subject.constraintLabel.toUpperCase()
                                    }
                                    color: root.ink
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                            }
                        }
                    }

                    // Page switcher.
                    Row {
                        visible: !root.chooseMode
                        height: visible ? implicitHeight : 0
                        spacing: 8
                        Repeater {
                            model: root.pages
                            Action {
                                required property int index
                                required property var modelData
                                text: modelData.label
                                selected: root.active === modelData.key
                                accent: {
                                    var s = root.sectionFor(modelData.key)
                                    return s ? s.tint : root.ink
                                }
                                onClicked: root.active = modelData.key
                            }
                        }
                    }

                    ConstraintsPage {
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'constraints'
                        height: visible ? implicitHeight : 0
                    }
                    OverviewPage {
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'overview'
                        height: visible ? implicitHeight : 0
                    }
                    CpuSection {
                        id: cpuSection
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'cpu'
                        height: visible ? implicitHeight : 0
                    }
                    RamSection {
                        id: ramSection
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'ram'
                        height: visible ? implicitHeight : 0
                    }
                    DiskSection {
                        id: diskSection
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'disk'
                        height: visible ? implicitHeight : 0
                    }
                    NetSection {
                        id: netSection
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'net'
                        height: visible ? implicitHeight : 0
                    }
                    SettingsPage {
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'settings'
                        height: visible ? implicitHeight : 0
                    }
                    AboutPage {
                        host: root
                        width: parent.width
                        visible: !root.chooseMode && root.active === 'about'
                        height: visible ? implicitHeight : 0
                    }

                    ChooserPage {
                        host: root
                        width: parent.width
                        visible: root.chooseMode
                        height: visible ? implicitHeight : 0
                    }

                    Rectangle { width: parent.width; height: 1; color: root.rule }
                    Label {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        font.pixelSize: 10
                        text: root.actionStatus || (root.chooseMode
                              ? 'Pick a readout to pin the icon, or Auto to let it follow the constraint  ·  Esc closes'
                              : (root.barAuto ? 'Icon follows the biggest constraint'
                                              : 'Icon pinned to ' + (root.barDomain ? root.barDomain.sectionTitle : root.barSource))
                                + '  ·  right-click it to change  ·  ← → switches pages  ·  Esc closes')
                    }
                }
            }
        }
    }
}
