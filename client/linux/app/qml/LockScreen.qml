import QtQuick
import QtQuick.Controls
import Oshinobu.Core

// Блокировка приложения PIN-кодом (как на Android/iOS).
Rectangle {
    color: Ui.c.background
    MouseArea { anchors.fill: parent }
    Column {
        anchors.centerIn: parent
        spacing: 18
        width: 280
        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: "qrc:/qt/qml/Oshinobu/icons/oshinobu.png"
            width: 72
            height: 72
        }
        Text {
            text: Ui.t("applock_enterPin")
            color: Ui.c.textPrimary
            font.pixelSize: 18
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Field {
            id: pin
            width: parent.width
            secret: true
            horizontalAlignment: Text.AlignHCenter
            inputMethodHints: Qt.ImhDigitsOnly
            validator: RegularExpressionValidator { regularExpression: /[0-9]{0,8}/ }
            focus: parent.visible
            onAccepted: tryUnlock()
            onTextChanged: if (text.length >= App.appLock.pinLength) tryUnlock()
            function tryUnlock() {
                if (App.unlock(text)) { text = ""; wrong.visible = false }
                else { wrong.visible = true; text = "" }
            }
        }
        Text {
            id: wrong
            visible: false
            text: Ui.t("applock_wrongPin")
            color: "#E5534B"
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}
