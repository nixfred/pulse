import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Right-click lands here: every readout the bar icon can show, in one list.
//
// The first row is Auto, and it is the default. Everything under it is a pin —
// a domain plus one of that domain's readouts — and picking one stops the icon
// moving. Each row shows what it would read right now, so the choice is made
// against live values rather than against a name.
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
    component Choice: Rectangle {
        id: act
        property string text: ''
        property string trailing: ''
        property bool selected: false
        property color accent: root.ink
        signal clicked()
        implicitHeight: 36
        radius: 9
        color: act.selected ? Qt.alpha(accent, Style.selectedFillAlpha) : area.containsMouse ? Style.hoverFill : Style.normalFill
        border.color: act.selected ? accent : area.containsMouse ? Style.hoverBorderColor : Style.normalBorderColor
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            x: 14
            width: parent.width - 28 - trail.implicitWidth
            text: act.text
            color: act.selected ? root.ink : root.inkDim
            font.pixelSize: 12
            font.bold: act.selected
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }
        Text {
            id: trail
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 14
            text: act.trailing
            color: act.accent
            font.family: Style.font.family
            font.pixelSize: 12
            font.bold: true
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

    Column {
        id: column
        width: parent.width
        spacing: 8

        Column {
            width: parent.width
            spacing: 3
            Heading { text: 'WHAT THE ICON SHOWS'; font.letterSpacing: 1.5 }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text: 'One icon, and by default it is not a fixed reading — it follows whichever of the four is most constrained and tells you which one that is. Pin any readout below to stop it moving.'
            }
        }

        Choice {
            width: parent.width
            implicitHeight: 46
            accent: host.barDomain ? host.barDomain.tint : root.ink
            selected: host.barAuto
            text: 'Auto  ·  follow the biggest constraint'
            trailing: host.barDomain ? host.barDomain.sectionTitle.toUpperCase() + ' ' + host.barDomain.headline : '—'
            onClicked: host.pinBar('auto', null)
        }
        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: 10
            visible: host.barAuto
            text: host.barDomain ? 'Right now that is ' + host.barDomain.sectionTitle + ': ' + host.barDomain.constraintLabel.toLowerCase()
                               + ' at ' + host.barDomain.constraintValue + '.' : ''
        }

        Repeater {
            model: host.domains
            Column {
                id: group
                required property var modelData
                required property int index
                readonly property string key: host.domainKeys[index]
                width: column.width
                spacing: 6

                Row {
                    spacing: 8
                    Heading {
                        text: group.modelData.sectionTitle.toUpperCase()
                        font.pixelSize: 12
                        font.letterSpacing: 1.5
                        color: group.modelData.tint
                    }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: 10
                        text: group.modelData.stale ? 'recorder offline'
                                                    : group.modelData.constraintLabel.toLowerCase() + ' · ' + group.modelData.constraintValue
                    }
                }
                // Two columns. Twenty readouts in one column does not fit a
                // screen, and a chooser you have to scroll is a chooser that
                // hides half its options.
                Flow {
                    width: group.width
                    spacing: 6
                    Repeater {
                        model: group.modelData.modeCount
                        Choice {
                            required property int index
                            width: (group.width - 6) / 2
                            accent: group.modelData.tint
                        // Pinned means this domain AND this readout. Selecting a
                        // different readout of the same domain repins rather
                        // than silently changing what auto would have shown.
                            selected: host.barSource === group.key && group.modelData.mode === index
                            text: group.modelData.modeLabel(index)
                            onClicked: host.pinBar(group.key, index)
                        }
                    }
                }
            }
        }

        Item { width: 1; height: 4 }
        Choice {
            width: parent.width
            text: 'Open the dashboard  →'
            onClicked: { host.chooseMode = false; host.showPage('overview') }
        }
    }
}
