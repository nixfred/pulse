import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The page that only exists because the four are together: how is this machine,
// answered in one glance, with a way into whichever domain the answer implicates.
//
// Each card is that domain's own chip, its own readout in its own grammar, its
// own verdict and its own history line — not a re-derived summary. Clicking a
// card opens that domain's full dashboard, which is the original plugin's panel
// in its entirety.
Item {
    id: root
    required property var host
    width: parent ? parent.width : 0
    implicitHeight: grid.implicitHeight + 10 + footer.implicitHeight

    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)

    Column {
        id: grid
        width: parent.width
        spacing: 10
        Repeater {
            model: host.domains
            Rectangle {
                id: cardRect
                required property var modelData
                required property int index
                readonly property string key: host.domainKeys[index]
                readonly property bool worst: host.worst === modelData
                width: grid.width
                height: 118
                radius: 14
                color: root.card
                // The worst domain wears its own tint on the border, so the
                // card you need is the one that stands out before you read a
                // single number.
                border.color: cardRect.worst ? Qt.alpha(modelData.tint, 0.65) : root.cardEdge
                border.width: cardRect.worst ? 2 : 1

                Row {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 14

                    Loader {
                        anchors.verticalCenter: parent.verticalCenter
                        sourceComponent: cardRect.modelData.cardChip
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 176
                        spacing: 4
                        Text {
                            text: cardRect.modelData.sectionTitle.toUpperCase()
                            color: root.inkDim
                            font.pixelSize: 10
                            font.letterSpacing: 1.4
                            textFormat: Text.PlainText
                        }
                        Text {
                            text: cardRect.modelData.headline
                            color: root.ink
                            font.family: Style.font.family
                            font.pixelSize: 26
                            font.bold: true
                            textFormat: Text.PlainText
                        }
                        Row {
                            spacing: 6
                            Text {
                                text: cardRect.modelData.tag
                                color: cardRect.modelData.tint
                                font.pixelSize: 9
                                font.letterSpacing: 0.8
                                textFormat: Text.PlainText
                            }
                            Text {
                                text: '·'
                                color: root.inkDim
                                font.pixelSize: 9
                            }
                            Text {
                                text: cardRect.modelData.verdict
                                color: root.inkDim
                                font.pixelSize: 9
                                font.bold: true
                                textFormat: Text.PlainText
                            }
                        }
                        // The card's own worst reading, named. Without it a
                        // card can look calm while one number inside it is not.
                        Text {
                            text: cardRect.modelData.constraintLabel + ' · ' + cardRect.modelData.constraintValue
                            color: root.inkDim
                            font.pixelSize: 9
                            textFormat: Text.PlainText
                        }
                    }

                    // The same history line the domain's own Overview draws,
                    // at card height. Hovering it still inspects, because it
                    // is the identical component.
                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        // The domain's own history trace with its axis labels
                        // turned off, so the card shows the shape of the last
                        // hour without the scaffolding that needs a full-height
                        // chart to fit. The labelled version is one click away.
                        width: parent.width - 88 - 176 - 28 - 66
                        height: 88
                        clip: true
                        Loader {
                            anchors.fill: parent
                            sourceComponent: cardRect.modelData.cardGraph
                            onLoaded: { if (item) { item.width = Qt.binding(function () { return parent.width }); item.height = Qt.binding(function () { return parent.height }) } }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 54
                        horizontalAlignment: Text.AlignRight
                        text: 'Open  →'
                        color: root.inkDim
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // The graph underneath wants the hover for its crosshair,
                    // so this only claims the click.
                    acceptedButtons: Qt.LeftButton
                    propagateComposedEvents: true
                    onClicked: function (mouse) { host.showPage(cardRect.key) }
                }
            }
        }
    }

    Text {
        id: footer
        anchors.top: grid.bottom
        anchors.topMargin: 10
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.inkDim
        font.pixelSize: 10
        textFormat: Text.PlainText
        text: 'Each card opens that domain\'s full dashboard — every reading, table and control the separate plugin had. Constraints ranks all four against one another.'
    }
}
