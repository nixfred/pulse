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
        {key: 'overview', label: 'Overview'},
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

    function chipEnabled(key) { return !!root.setting(key + '.inBar', true) }
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
        function modes(): void { root.chooseMode = false; root.active = 'settings'; root.open() }
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
    // One button, four chips. Each chip is the original plugin's own bar chip,
    // instantiated from a Component the section owns, so it keeps its own
    // animation, tint and readout grammar. Clicking a chip opens that domain
    // directly; clicking the gap opens the Overview.
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        labelVisible: false
        hasVisualContent: true
        fixedWidth: vertical ? -1 : barRow.implicitWidth + 12
        tooltipText: {
            var parts = []
            for (var i = 0; i < root.domains.length; i++) {
                var d = root.domains[i]
                if (!d || !root.chipEnabled(root.domainKeys[i])) continue
                parts.push(d.sectionTitle + ': ' + (d.stale ? 'telemetry offline' : d.headline + ' ' + d.tag))
            }
            return 'Pulse\n' + parts.join('\n') + '\nLeft-click: overview · Right-click: settings'
        }
        onPressed: function (b) {
            if (b === Qt.RightButton) { root.active = 'settings'; root.open() }
            else { root.chooseMode = false; root.active = 'overview'; root.toggle() }
        }
        // Row lays its own children out, so each cell is an Item and the
        // centring happens inside it. Anchoring a direct child of a Row
        // switches the Row's layout off entirely.
        Row {
            id: barRow
            anchors.centerIn: parent
            spacing: 8
            Repeater {
                model: root.domains
                Item {
                    id: chipCell
                    required property var modelData
                    required property int index
                    readonly property string key: root.domainKeys[index]
                    visible: root.chipEnabled(key)
                    implicitWidth: visible ? cellRow.implicitWidth : 0
                    implicitHeight: cellRow.implicitHeight
                    width: implicitWidth
                    height: implicitHeight
                    Row {
                        id: cellRow
                        anchors.centerIn: parent
                        spacing: 4
                        Loader { sourceComponent: chipCell.modelData.barChip }
                        Column {
                            visible: root.setting(chipCell.key + '.showReadout', true)
                            Text {
                                text: chipCell.modelData.headline
                                color: root.barForeground
                                font.family: Style.font.family
                                font.pixelSize: 12
                                font.bold: true
                                textFormat: Text.PlainText
                            }
                            Text {
                                text: chipCell.modelData.tag
                                color: chipCell.modelData.tint
                                font.pixelSize: 7
                                font.letterSpacing: 0.8
                                textFormat: Text.PlainText
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onClicked: root.openSection(chipCell.key)
                    }
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
        contentWidth: panel.fittedContentWidth(760)
        contentHeight: panel.fittedContentHeight(Math.min(shell.implicitHeight, 760))
        Item {
            id: body
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.close()
            Keys.onPressed: function (event) {
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
                            width: parent.width - 250
                            spacing: 3
                            Heading {
                                text: root.active === 'overview' || root.active === 'settings' || root.active === 'about'
                                      ? 'PULSE' : (root.sectionFor(root.active) ? root.sectionFor(root.active).sectionTitle.toUpperCase() + ' PULSE' : 'PULSE')
                                font.pixelSize: 19
                                font.letterSpacing: 3
                            }
                            Label {
                                text: {
                                    var s = root.sectionFor(root.active)
                                    if (s) return s.sectionBlurb + (root.version !== '' ? '   ·   v' + root.version : '')
                                    return 'CPU, memory, storage and network in one place.' + (root.version !== '' ? '   ·   v' + root.version : '')
                                }
                                font.pixelSize: 11
                            }
                        }
                        Rectangle {
                            id: verdictPill
                            width: 240
                            height: 32
                            radius: 16
                            // On a domain page the pill speaks for that domain.
                            // On Overview, Settings or About it speaks for the
                            // unhappiest domain, which is the reading you most
                            // need to see without choosing a page first.
                            readonly property var subject: root.sectionFor(root.active) || root.worst
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
                                    text: verdictPill.subject ? verdictPill.subject.verdict : 'WAITING FOR TELEMETRY'
                                    color: root.ink
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                            }
                        }
                    }

                    // Page switcher.
                    Row {
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

                    OverviewPage {
                        host: root
                        width: parent.width
                        visible: root.active === 'overview'
                        height: visible ? implicitHeight : 0
                    }
                    CpuSection {
                        id: cpuSection
                        host: root
                        width: parent.width
                        visible: root.active === 'cpu'
                        height: visible ? implicitHeight : 0
                    }
                    RamSection {
                        id: ramSection
                        host: root
                        width: parent.width
                        visible: root.active === 'ram'
                        height: visible ? implicitHeight : 0
                    }
                    DiskSection {
                        id: diskSection
                        host: root
                        width: parent.width
                        visible: root.active === 'disk'
                        height: visible ? implicitHeight : 0
                    }
                    NetSection {
                        id: netSection
                        host: root
                        width: parent.width
                        visible: root.active === 'net'
                        height: visible ? implicitHeight : 0
                    }
                    SettingsPage {
                        host: root
                        width: parent.width
                        visible: root.active === 'settings'
                        height: visible ? implicitHeight : 0
                    }
                    AboutPage {
                        host: root
                        width: parent.width
                        visible: root.active === 'about'
                        height: visible ? implicitHeight : 0
                    }

                    Rectangle { width: parent.width; height: 1; color: root.rule }
                    Label {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        font.pixelSize: 10
                        text: root.actionStatus || 'Four recorders, 7-day retention, this machine only  ·  ← → switches pages  ·  Esc closes'
                    }
                }
            }
        }
    }
}
