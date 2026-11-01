import QtQuick
import QtQuick.Controls

// Кнопка: основная (заливка) или вторичная (контур / текст).
Button {
    id: b
    property bool primary: true
    property bool danger: false
    property bool outline: false
    font.pixelSize: 15
    font.bold: primary
    implicitHeight: 44
    leftPadding: 18
    rightPadding: 18
    contentItem: Text {
        text: b.text
        font: b.font
        color: b.primary ? Ui.c.onPrimary : (b.danger ? "#E5534B" : Ui.c.primary)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        opacity: b.enabled ? 1 : 0.5
        elide: Text.ElideRight
    }
    scale: down ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: 90 } }
    background: Rectangle {
        radius: Ui.radius
        color: b.primary ? (b.danger ? "#E5534B" : Ui.c.primary) : (b.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.12) : "transparent")
        border.width: b.outline ? 1 : 0
        border.color: b.danger ? "#E5534B" : Ui.c.primary
        opacity: b.enabled ? (b.down ? 0.8 : 1) : 0.5
        Behavior on color { ColorAnimation { duration: 120 } }
    }
}
