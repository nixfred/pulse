import QtQuick
import "Constraints.js" as C

// Shared chrome for Pulse (audit #22): one source for card/action geometry,
// type sizes and the severity scale behind the Constraints page.
//
// Two things live here:
//   * values and helpers (radii, sizes, severityColor/severityWord) —
//     instantiated as `PulseChrome { id: chrome }` by Panel.qml and
//     ConstraintsPage.qml, which bind real theme colours into it;
//   * the canonical Label/Heading/Action/Stat definitions below them.
//     QML inline components are file-scoped, so each page keeps its own
//     `component` aliases; those aliases are kept byte-identical to these and
//     say so in a comment, rather than drifting apart file by file.
QtObject {
    id: chrome

    // Theme inputs. Hosts bind these to their own roles.
    property color ink: '#edf5f7'
    property color inkDim: '#9db2bc'
    property color card: '#1c2a33'
    property color cardEdge: '#2c3f4a'
    property color accent: '#ffffff'
    property color urgent: '#e5484d'
    property color soft: '#8a9aa3'
    property string fontFamily: 'sans-serif'

    // Geometry shared by every card, button and pill.
    readonly property int cardRadius: 14
    readonly property int actionRadius: 9
    readonly property int pillRadius: 16
    readonly property int headingSize: 15
    readonly property int labelSize: 12
    readonly property int captionSize: 10
    readonly property int statusExpiryMs: 8000

    // One colour scale for severity, independent of any domain's own tint, so
    // a red bar means the same thing in every row. Delegates to
    // Constraints.bandColor (audit #23): thresholds live in one place.
    function severityColor(severity) {
        return C.bandColor(Number(severity) || 0, chrome.urgent, chrome.soft)
    }
    function severityWord(severity) {
        var s = Number(severity) || 0
        return s >= C.HIGH ? 'CRITICAL' : s >= C.MEDIUM ? 'TIGHT'
             : s >= C.LOW ? 'NOTICEABLE' : 'COMFORTABLE'
    }

    // ---- canonical components (copy source; see header) ------------------
    component Label: Text {
        color: chrome.inkDim
        font.pixelSize: 12
        font.family: chrome.fontFamily
        textFormat: Text.PlainText
    }
    component Heading: Text {
        color: chrome.ink
        font.pixelSize: 15
        font.bold: true
        font.family: chrome.fontFamily
        textFormat: Text.PlainText
    }
    component Action: Rectangle {
        id: act
        property string text: ''
        property bool selected: false
        property color accent: chrome.accent
        signal clicked()
        implicitWidth: caption.implicitWidth + 26
        implicitHeight: 34
        radius: 9
        color: act.selected ? Qt.alpha(accent, 0.18) : area.containsMouse ? Qt.alpha(chrome.ink, 0.08) : chrome.card
        border.color: act.selected ? accent : area.containsMouse ? chrome.cardEdge : chrome.cardEdge
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            id: caption
            anchors.centerIn: parent
            text: act.text
            color: act.selected ? chrome.ink : chrome.inkDim
            font.pixelSize: 12
            font.family: chrome.fontFamily
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
    component Stat: Rectangle {
        property string label: ''
        property string value: ''
        property string hint: ''
        radius: 14
        color: chrome.card
        border.color: chrome.cardEdge
        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 5
            Text { text: label; color: chrome.inkDim; font.pixelSize: 10; font.family: chrome.fontFamily; font.letterSpacing: 1; textFormat: Text.PlainText }
            Text { text: value; color: chrome.ink; font.pixelSize: 20; font.family: chrome.fontFamily; textFormat: Text.PlainText }
            Text { text: hint; color: chrome.inkDim; font.pixelSize: 10; font.family: chrome.fontFamily; textFormat: Text.PlainText }
        }
    }
}
