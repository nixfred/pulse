import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Where this machine is actually weak.
//
// The four domain pages each answer "how is my CPU / RAM / disk / network".
// None of them can answer "which of those is the problem", because none of them
// can see the other three. That question is the reason to merge the plugins at
// all, so it gets its own page.
//
// Every row is scored on one shared 0..1 severity scale (sections/Constraints.js),
// which is what makes CPU heat and disk space comparable in the first place. The
// same scores drive the bar icon, so what the icon is showing you is always the
// top row here.
Item {
    id: root
    required property var host
    width: parent ? parent.width : 0
    implicitHeight: column.implicitHeight

    readonly property color ink: Color.popups.text
    readonly property color inkDim: Util.alpha(ink, 0.66)
    readonly property color card: Util.alpha(ink, 0.05)
    readonly property color cardEdge: Util.alpha(ink, 0.15)

    // Domains worst first. The ranking is the finding, so the page is ordered
    // by it rather than by a fixed CPU/RAM/Disk/Net order that would bury it.
    readonly property var ranked: {
        var list = []
        for (var i = 0; i < host.domains.length; i++) if (host.domains[i]) list.push(host.domains[i])
        return list.sort(function (a, b) { return b.concern - a.concern })
    }
    // One colour scale for severity, independent of any domain's own tint, so
    // a red bar means the same thing in every row on the page.
    function severityColor(severity) {
        if (severity >= 0.85) return Color.urgent
        if (severity >= 0.62) return Qt.rgba(0.92, 0.66, 0.25, 1)
        if (severity >= 0.34) return Qt.rgba(0.85, 0.80, 0.35, 1)
        return Util.alpha(root.ink, 0.45)
    }
    function severityWord(severity) {
        return severity >= 0.85 ? 'CRITICAL' : severity >= 0.62 ? 'TIGHT'
             : severity >= 0.34 ? 'NOTICEABLE' : 'COMFORTABLE'
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

    Column {
        id: column
        width: parent.width
        spacing: 9

        Column {
            width: parent.width
            spacing: 4
            Heading { text: 'BIGGEST CONSTRAINT'; font.letterSpacing: 1.5 }
            Row {
                spacing: 10
                Text {
                    text: root.ranked.length ? root.ranked[0].sectionTitle.toUpperCase() : '—'
                    color: root.ranked.length ? root.ranked[0].tint : root.ink
                    font.pixelSize: 26
                    font.bold: true
                    font.letterSpacing: 1
                    textFormat: Text.PlainText
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.ranked.length && root.ranked[0].topConstraint
                          ? root.ranked[0].constraintLabel + ' · ' + root.ranked[0].constraintValue : ''
                    color: root.ink
                    font.pixelSize: 15
                    textFormat: Text.PlainText
                }
            }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.ranked.length && root.ranked[0].topConstraint ? root.ranked[0].topConstraint.detail : ''
            }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: 10
                text: host.barAuto ? 'The bar icon is following this and will move on its own when something else becomes tighter.'
                                   : 'The bar icon is pinned to ' + (host.barDomain ? host.barDomain.sectionTitle : host.barSource)
                                     + ', so it will not move. Right-click the icon to put it back on auto.'
            }
        }

        Repeater {
            model: root.ranked
            Rectangle {
                id: block
                required property var modelData
                required property int index
                width: column.width
                height: inner.implicitHeight + 24
                radius: 14
                color: root.card
                border.color: block.index === 0 ? Qt.alpha(modelData.tint, 0.6) : root.cardEdge
                border.width: block.index === 0 ? 2 : 1

                Column {
                    id: inner
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 6

                    Row {
                        width: parent.width
                        spacing: 8
                        Text {
                            text: String(block.index + 1)
                            color: root.inkDim
                            font.pixelSize: 12
                            font.bold: true
                            width: 14
                            textFormat: Text.PlainText
                        }
                        Heading {
                            text: block.modelData.sectionTitle.toUpperCase()
                            font.pixelSize: 13
                            font.letterSpacing: 1.5
                            color: block.modelData.tint
                        }
                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            font.pixelSize: 10
                            text: block.modelData.stale ? 'recorder offline'
                                                        : block.modelData.headline + ' ' + block.modelData.tag
                        }
                        Item { width: 2; height: 1 }
                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            font.pixelSize: 9
                            visible: block.modelData.constraints.length > 3
                            text: '+' + (block.modelData.constraints.length - 3) + ' more inside'
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.severityWord(block.modelData.concern)
                            color: root.severityColor(block.modelData.concern)
                            font.pixelSize: 9
                            font.bold: true
                            font.letterSpacing: 1
                            textFormat: Text.PlainText
                        }
                    }

                    Repeater {
                        // The top few only. A domain's fifth-worst reading is
                        // not a finding, and the page has to fit on one screen
                        // to be read at a glance at all.
                        model: block.modelData.constraints.slice(0, 3)
                        Row {
                            required property var modelData
                            width: inner.width
                            spacing: 10

                            // The bar is the comparison. Reading down the page,
                            // the eye ranks the weaknesses before it reads a
                            // single number.
                            Rectangle {
                                width: 4
                                height: 28
                                radius: 2
                                anchors.verticalCenter: parent.verticalCenter
                                color: Util.alpha(root.ink, 0.12)
                                Rectangle {
                                    width: parent.width
                                    height: Math.max(3, parent.height * modelData.severity)
                                    anchors.bottom: parent.bottom
                                    radius: 2
                                    color: root.severityColor(modelData.severity)
                                }
                            }
                            Column {
                                id: readingCol
                                width: 210
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Text {
                                    width: parent.width
                                    text: modelData.label
                                    color: root.ink
                                    font.pixelSize: 11
                                    font.bold: true
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                }
                                Text {
                                    // Some readings carry a whole clause, like
                                    // zram's compression ratio. Eliding keeps
                                    // them out of the explanation beside them.
                                    width: parent.width
                                    text: modelData.value
                                    color: root.severityColor(modelData.severity)
                                    font.family: Style.font.family
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                }
                            }
                            Text {
                                width: inner.width - 4 - 210 - 20
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.detail
                                color: root.inkDim
                                font.pixelSize: 10
                                wrapMode: Text.WordWrap
                                textFormat: Text.PlainText
                            }
                        }
                    }

                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: host.showPage(host.domainKeys[host.domains.indexOf(block.modelData)])
                }
            }
        }

        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            font.pixelSize: 10
            text: 'One 0–1 severity scale across all four, so a hot drive and a busy processor compare directly. Click any card for that domain\'s full dashboard.'
        }
    }
}
