import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// What this plugin is, what it replaced, and where each part came from.
// Per-domain detail — versions, recorder state, retention — stays on each
// domain's own About tab, because that is where it was and where it belongs.
Item {
    id: root
    required property var host
    width: parent ? parent.width : 0
    implicitHeight: column.implicitHeight

    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)

    readonly property string repoUrl: 'https://github.com/nixfred/pulse'
    readonly property string siteUrl: 'https://nixfred.com'

    readonly property var upstream: [
        {name: 'CPU Pulse',  repo: 'https://github.com/nixfred/omacpu',                 unit: 'cpu-pulse.service'},
        {name: 'RAM Pulse',  repo: 'https://github.com/nixfred/ram.plugin.omarchy',     unit: 'ram-pulse.service'},
        {name: 'Disk Pulse', repo: 'https://github.com/nixfred/disk.pulse',             unit: 'disk-pulse.service'},
        {name: 'Net Pulse',  repo: 'https://github.com/nixfred/omanet.plugin.omarchy',  unit: 'net-pulse.service'}
    ]

    Process {
        id: opener
        onExited: function (code) { if (code !== 0) host.actionStatus = 'Could not open that link.' }
    }
    function openUrl(url) {
        if (opener.running) return
        host.actionStatus = 'Opening ' + url + ' in your browser…'
        opener.command = ['xdg-open', String(url)]
        opener.running = true
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
    component Link: Text {
        id: link
        property string url: ''
        color: linkArea.containsMouse ? root.ink : root.inkDim
        font.pixelSize: 12
        font.underline: linkArea.containsMouse
        textFormat: Text.PlainText
        MouseArea {
            id: linkArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openUrl(link.url)
        }
    }
    component Stat: Rectangle {
        property string label: ''
        property string value: ''
        property string hint: ''
        radius: 12
        color: root.card
        border.color: root.cardEdge
        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 5
            Label { text: label; font.pixelSize: 10; font.letterSpacing: 1 }
            Heading { text: value; font.pixelSize: 20 }
            Label { text: hint; font.pixelSize: 10 }
        }
    }

    Column {
        id: column
        width: parent.width
        spacing: 14

        Column {
            width: parent.width
            spacing: 6
            Heading { text: 'PULSE'; font.letterSpacing: 2 }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text: 'One widget for the four readings that tell you what a machine is doing: how hard it is thinking, how much it can still remember, how much room it has left, and whether it can reach anything. Four plugins used to do this from four bar entries. This is those four, whole, behind one chip row.'
            }
        }

        // Where this came from and where it lives. At the top, because an
        // About page whose links are below the fold is an About page nobody
        // follows.
        Row {
            width: parent.width
            spacing: 8
            Text {
                text: 'Source'
                color: root.inkDim
                font.pixelSize: 12
                font.bold: true
                textFormat: Text.PlainText
            }
            Link { text: 'github.com/nixfred/pulse'; url: root.repoUrl }
            Text { text: '·'; color: root.inkDim; font.pixelSize: 12 }
            Text {
                text: 'Built by'
                color: root.inkDim
                font.pixelSize: 12
                font.bold: true
                textFormat: Text.PlainText
            }
            Link { text: 'nixfred.com'; url: root.siteUrl }
            Text { text: '·'; color: root.inkDim; font.pixelSize: 12 }
            Text {
                text: 'MIT'
                color: root.inkDim
                font.pixelSize: 12
                textFormat: Text.PlainText
            }
        }

        Row {
            width: parent.width
            spacing: 10
            Stat {
                width: (parent.width - 30) / 4
                height: 91
                label: 'VERSION'
                value: host.version !== '' ? 'v' + host.version : '—'
                hint: 'this merged plugin'
            }
            Stat {
                width: (parent.width - 30) / 4
                height: 91
                label: 'RECORDERS'
                value: {
                    var live = 0
                    for (var i = 0; i < host.domains.length; i++) if (host.domains[i] && !host.domains[i].stale) live++
                    return live + ' of 4'
                }
                hint: 'user services, still separate'
            }
            Stat {
                width: (parent.width - 30) / 4
                height: 91
                label: 'RETENTION'
                value: '7 days'
                hint: 'aggregate metrics, this machine only'
            }
            Stat {
                width: (parent.width - 30) / 4
                height: 91
                label: 'LEAVES THE BOX'
                value: 'nothing'
                hint: 'no network calls, no telemetry'
            }
        }

        Column {
            width: parent.width
            spacing: 6
            Label { text: 'WHAT THIS REPLACED'; font.pixelSize: 10; font.letterSpacing: 1.5 }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text: 'Each domain page below is the original plugin\'s dashboard in full — the same tabs, tables, controls and numbers, reading the same recorder and the same seven days of history. The merge added three pages that could not exist before: the Overview, Constraints, and this one.'
            }
            Repeater {
                model: root.upstream
                Row {
                    required property var modelData
                    spacing: 8
                    Label { text: '·'; font.pixelSize: 11 }
                    Label { text: modelData.name; color: root.ink; font.pixelSize: 11; width: 90 }
                    Label { text: modelData.unit; font.pixelSize: 11; width: 130 }
                    Link {
                        text: modelData.repo.replace(/^https?:\/\//, '')
                        url: modelData.repo
                        font.pixelSize: 11
                    }
                }
            }
        }

        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: 10
            text: 'The four collectors were left as they were. They keep their own units, their own state directories and their own history files, so the merge cost no recorded history and any one of them can still be debugged on its own.'
        }
    }
}
