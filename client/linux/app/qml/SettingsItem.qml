import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Пункт бокового меню как на Android: цветной квадрат со значком и подпись.
ItemDelegate {
    id: item
    property string glyph
    property color tint
    property string label
    property string value
    property bool danger: false
    width: parent ? parent.width : 0
    height: 46
    leftPadding: 16
    rightPadding: 16
    // пункт открывает модальное окно, и «курсор ушёл» до пункта уже не доходит — подсветка
    // залипала; сбрасываем её сами (обработчик у экземпляра тоже вызывается)
    onClicked: {
        hoverEnabled = false
        Qt.callLater(() => hoverEnabled = true)
    }
    // подсветка — скруглённая и с отступом от краёв (острых углов в приложении нет)
    background: Item {
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: 10
            color: item.down ? Qt.rgba(0.5, 0.5, 0.5, 0.18) : item.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.1) : "transparent"
            Behavior on color { ColorAnimation { duration: 100 } }
        }
    }
    contentItem: RowLayout {
        spacing: 14
        Rectangle {
            implicitWidth: 28
            implicitHeight: 28
            radius: 8
            color: item.tint
            Text { anchors.centerIn: parent; text: item.glyph; color: "white"; font.pixelSize: 14 }
        }
        Text {
            Layout.fillWidth: true
            text: item.label
            color: item.danger ? "#E5534B" : Ui.c.textPrimary
            font.pixelSize: 15
            elide: Text.ElideRight
        }
        Text {
            visible: item.value.length > 0
            text: item.value
            color: Ui.c.textMuted
            font.pixelSize: 13
            elide: Text.ElideRight
            Layout.maximumWidth: 140
        }
    }
}
