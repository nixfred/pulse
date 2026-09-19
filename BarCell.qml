import QtQuick

// One bar cell: a domain chip plus its two-line readout (audit #21).
//
// The Panel bar used to spell this cell twice — once as a Row for horizontal
// bars, once as a Column for vertical bars — and the two copies had to be
// kept identical by hand. Both Repeaters now delegate here with isVertical
// selecting the layout; behaviour (spacing, ceilings, elide, separator) is
// unchanged.
Item {
    id: root
    // The domain's own chip component (section.barChip).
    required property var chip
    // Line one: the readout in the domain's own grammar.
    required property string headline
    // Line two: OFFLINE / the auto caption / title + tag.
    required property string caption
    property color foreground: '#ffffff'
    property color captionInk: '#ffffff'
    // Per-cell caption ceiling: constraint labels carry mount paths, so an
    // unbounded caption could ask the bar to re-lay out by a hundred pixels
    // between samples. Matches Model.CAPTION_CEIL.
    property int ceiling: 110
    property bool isVertical: false
    property string fontFamily: 'sans-serif'
    // Separator between cells, never after the last one; computed by the host.
    property bool showSeparator: false

    implicitWidth: root.isVertical ? col.implicitWidth : row.implicitWidth
    implicitHeight: root.isVertical ? col.implicitHeight : row.implicitHeight

    Row {
        id: row
        visible: !root.isVertical
        anchors.centerIn: parent
        spacing: 5
        Loader {
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: root.chip
        }
        Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            Text {
                text: root.headline
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: 12
                font.bold: true
                elide: Text.ElideRight
                width: Math.min(implicitWidth, root.ceiling)
                textFormat: Text.PlainText
            }
            Text {
                text: root.caption
                color: root.captionInk
                font.pixelSize: 7
                font.letterSpacing: 0.6
                font.bold: true
                elide: Text.ElideRight
                width: Math.min(implicitWidth, root.ceiling)
                textFormat: Text.PlainText
            }
        }
        Rectangle {
            visible: root.showSeparator
            width: 1
            height: 22
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            opacity: 0.18
        }
    }

    Column {
        id: col
        visible: root.isVertical
        anchors.centerIn: parent
        spacing: 2
        Loader {
            anchors.horizontalCenter: parent.horizontalCenter
            sourceComponent: root.chip
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.headline
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: 12
            font.bold: true
            elide: Text.ElideRight
            width: Math.min(implicitWidth, root.ceiling)
            textFormat: Text.PlainText
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.caption
            color: root.captionInk
            font.pixelSize: 7
            font.letterSpacing: 0.6
            font.bold: true
            elide: Text.ElideRight
            width: Math.min(implicitWidth, root.ceiling)
            textFormat: Text.PlainText
        }
        Rectangle {
            visible: root.showSeparator
            width: 22
            height: 1
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.foreground
            opacity: 0.18
        }
    }
}
