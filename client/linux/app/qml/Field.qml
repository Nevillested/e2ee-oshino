import QtQuick
import QtQuick.Controls

// Поле ввода в стиле приложения.
TextField {
    id: f
    property bool secret: false
    color: Ui.c.textPrimary
    placeholderTextColor: Ui.c.textMuted
    selectionColor: Ui.c.primary
    selectedTextColor: Ui.c.onPrimary
    echoMode: secret ? TextInput.Password : TextInput.Normal
    font.pixelSize: 15
    leftPadding: 14
    rightPadding: 14
    topPadding: 11
    bottomPadding: 11
    background: Rectangle {
        radius: Ui.radius
        color: Ui.c.surface
        border.width: f.activeFocus ? 2 : 1
        border.color: f.activeFocus ? Ui.c.primary : Qt.rgba(0.5, 0.5, 0.5, 0.25)
        Behavior on border.color { ColorAnimation { duration: 150 } }
    }
}
