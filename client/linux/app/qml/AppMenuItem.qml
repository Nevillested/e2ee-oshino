import QtQuick
import QtQuick.Controls

// Пункт меню в цветах темы.
MenuItem {
    id: item
    property bool danger: false
    implicitHeight: visible ? 40 : 0
    leftPadding: 14
    rightPadding: 14
    contentItem: Text {
        text: item.text
        color: item.danger ? "#E5534B" : Ui.c.textPrimary
        opacity: item.enabled ? 1 : 0.4
        font.pixelSize: 15
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: 9
        color: item.highlighted ? Qt.rgba(Ui.c.primary.r, Ui.c.primary.g, Ui.c.primary.b, 0.16) : "transparent"
        Behavior on color { ColorAnimation { duration: 90 } }
    }
}
