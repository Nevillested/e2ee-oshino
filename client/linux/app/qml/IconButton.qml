import QtQuick
import QtQuick.Controls

// Круглая кнопка со значком (символ Unicode — без внешних шрифтов иконок).
AbstractButton {
    id: b
    property string glyph
    property color tint: Ui.c.textMuted
    property int size: 36
    property string tip
    implicitWidth: size
    implicitHeight: size
    hoverEnabled: true
    // подсказка в цветах темы, а не белая системная
    ToolTip {
        visible: b.tip.length > 0 && b.hovered
        text: b.tip
        delay: 600
        y: -height - 6
        contentItem: Text { text: b.tip; color: Ui.c.textPrimary; font.pixelSize: 12 }
        background: Rectangle { radius: 8; color: Ui.c.surface; border.color: Qt.rgba(0.5, 0.5, 0.5, 0.2) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 90 } }
    }
    contentItem: Text {
        text: b.glyph
        color: b.tint
        font.pixelSize: b.size * 0.5
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
        radius: width / 2
        color: b.down ? Qt.rgba(0.5, 0.5, 0.5, 0.25) : b.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.14) : "transparent"
        Behavior on color { ColorAnimation { duration: 100 } }
    }
}
