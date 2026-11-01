import QtQuick
import QtQuick.Controls

// Выбор одного варианта (вместо выпадающего списка): строки с отметкой, как в диалогах Android.
Sheet {
    id: sheet
    property var options: []      // [{ text, value }]
    property var current
    property var onChosen
    function ask(t, opts, cur, fn) { title = t; options = opts; current = cur; onChosen = fn; open() }
    Repeater {
        model: sheet.options
        delegate: ItemDelegate {
            width: parent ? parent.width : 0
            height: 46
            background: Rectangle { radius: 10; color: parent.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.12) : "transparent"; Behavior on color { ColorAnimation { duration: 100 } } }
            contentItem: Row {
                spacing: 12
                Rectangle {
                    width: 20; height: 20; radius: 10
                    anchors.verticalCenter: parent.verticalCenter
                    color: "transparent"
                    border.width: 2
                    border.color: modelData.value === sheet.current ? Ui.c.primary : Ui.c.textMuted
                    Rectangle {
                        anchors.centerIn: parent
                        width: 10; height: 10; radius: 5
                        color: Ui.c.primary
                        scale: modelData.value === sheet.current ? 1 : 0
                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                    }
                }
                Text { text: modelData.text; color: Ui.c.textPrimary; font.pixelSize: 15; anchors.verticalCenter: parent.verticalCenter }
            }
            onClicked: { sheet.current = modelData.value; if (sheet.onChosen) sheet.onChosen(modelData.value); sheet.close() }
        }
    }
}
