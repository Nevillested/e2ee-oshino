import QtQuick
import QtQuick.Controls

// Флажок в цветах темы: скруглённый квадрат, заливка и галочка с анимацией.
CheckBox {
    id: c
    spacing: 10
    indicator: Rectangle {
        x: c.leftPadding
        y: (c.height - height) / 2
        width: 20
        height: 20
        radius: 6
        color: c.checked ? Ui.c.primary : "transparent"
        border.width: c.checked ? 0 : 2
        border.color: Ui.c.textMuted
        opacity: c.enabled ? 1 : 0.5
        Behavior on color { ColorAnimation { duration: 140 } }
        Text {
            anchors.centerIn: parent
            text: "✓"
            color: Ui.c.onPrimary
            font.pixelSize: 14
            font.bold: true
            scale: c.checked ? 1 : 0
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
        }
    }
    contentItem: Text {
        text: c.text
        color: Ui.c.textPrimary
        font.pixelSize: 14
        leftPadding: c.indicator.width + c.spacing
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.Wrap
        opacity: c.enabled ? 1 : 0.5
    }
}
