import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Every setting the four plugins had, in one place, grouped by domain.
//
// Separately, each plugin hid its readout chooser behind a right-click on its
// own bar chip. With one bar entry that no longer works, so all four choosers
// live here — plus the two decisions that only exist once the four share a bar
// entry: which chips appear in it, and which of them carry a readout.
Item {
    id: root
    required property var host
    width: parent ? parent.width : 0
    implicitHeight: column.implicitHeight

    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)

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
            anchors.verticalCenter: parent.verticalCenter
            x: 13
            width: parent.width - 26
            text: act.text
            color: act.selected ? root.ink : root.inkDim
            font.pixelSize: 12
            font.bold: act.selected
            elide: Text.ElideRight
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
    // A labelled on/off pair. Two buttons rather than a switch, because the
    // rest of the panel says yes-or-no that way already.
    component Toggle: Row {
        id: row
        property string label: ''
        property bool value: false
        property color accent: root.ink
        signal picked(bool next)
        spacing: 8
        Label {
            width: 210
            text: row.label
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
        }
        Action {
            text: 'On'
            implicitWidth: 66
            implicitHeight: 28
            selected: row.value
            accent: row.accent
            onClicked: row.picked(true)
        }
        Action {
            text: 'Off'
            implicitWidth: 66
            implicitHeight: 28
            selected: !row.value
            accent: row.accent
            onClicked: row.picked(false)
        }
    }

    Column {
        id: column
        width: parent.width
        spacing: 14

        Repeater {
            model: host.domains
            Rectangle {
                id: block
                required property var modelData
                required property int index
                readonly property string key: host.domainKeys[index]
                width: column.width
                height: inner.implicitHeight + 28
                radius: 14
                color: root.card
                border.color: root.cardEdge

                Column {
                    id: inner
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 10

                    Row {
                        width: parent.width
                        spacing: 8
                        Heading {
                            text: block.modelData.sectionTitle.toUpperCase()
                            font.letterSpacing: 1.5
                            color: block.modelData.tint
                        }
                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            text: block.modelData.stale ? 'recorder offline' : block.modelData.headline + ' ' + block.modelData.tag
                            font.pixelSize: 10
                        }
                    }

                    Toggle {
                        label: 'Show this chip in the bar'
                        accent: block.modelData.tint
                        value: host.setting(block.key + '.inBar', true)
                        onPicked: function (next) { host.setSetting(block.key + '.inBar', next) }
                    }
                    Toggle {
                        label: 'Show its readout beside the chip'
                        accent: block.modelData.tint
                        value: host.setting(block.key + '.showReadout', true)
                        onPicked: function (next) { host.setSetting(block.key + '.showReadout', next) }
                    }
                    Toggle {
                        label: 'Animate the chip'
                        accent: block.modelData.tint
                        value: host.setting(block.key + '.animated', true)
                        onPicked: function (next) { host.setSetting(block.key + '.animated', next) }
                    }

                    // RAM is the one domain whose table has two shapes, and the
                    // choice is durable, so it belongs here as well as in the
                    // tab where you notice you want it.
                    Toggle {
                        visible: block.key === 'ram'
                        height: visible ? implicitHeight : 0
                        label: 'Group hoarders by app'
                        accent: block.modelData.tint
                        value: host.setting('ram.groupByApp', true) !== false
                        onPicked: function (next) { host.setSetting('ram.groupByApp', next) }
                    }

                    Row {
                        visible: block.key === 'disk'
                        height: visible ? implicitHeight : 0
                        spacing: 8
                        Label { width: 210; text: 'Filesystem the bar follows'; anchors.verticalCenter: parent.verticalCenter }
                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.ink
                            text: host.setting('disk.mountpoint', '/') + '   ·   pick another in Disk → Overview'
                        }
                    }

                    Rectangle { width: parent.width; height: 1; color: root.cardEdge }

                    Label {
                        text: 'BAR READOUT   ·   ' + block.modelData.modeHint
                        font.pixelSize: 10
                        font.letterSpacing: 1
                    }
                    Flow {
                        width: parent.width
                        spacing: 6
                        Repeater {
                            model: block.modelData.modeCount
                            Action {
                                required property int index
                                implicitWidth: Math.max(150, (inner.width - 18) / 2)
                                height: 34
                                accent: block.modelData.tint
                                selected: block.modelData.mode === index
                                text: block.modelData.modeLabel(index)
                                onClicked: block.modelData.setMode(index)
                            }
                        }
                    }
                }
            }
        }

        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: 10
            text: 'Settings are stored in this widget\'s shell.json entry, namespaced per domain, so the four no longer compete for the same keys.'
        }
    }
}
