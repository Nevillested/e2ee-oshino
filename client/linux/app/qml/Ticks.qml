import QtQuick

// Галочки доставки: «отправлено» — одна, «прочитано» — две внахлёст, как в Telegram;
// вторая появляется с лёгкой анимацией.
Item {
    id: root
    property bool read: false
    property color color
    property int pixelSize: 11
    implicitWidth: first.implicitWidth + (read ? second.implicitWidth * 0.45 : 0)
    implicitHeight: first.implicitHeight
    Behavior on implicitWidth { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Text { id: first; text: "✓"; color: root.color; font.pixelSize: root.pixelSize; font.bold: true }
    Text {
        id: second
        x: first.implicitWidth * 0.45
        text: "✓"
        color: root.color
        font.pixelSize: root.pixelSize
        font.bold: true
        opacity: root.read ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }
}
