import QtQuick
import QtQuick.Controls

// Модальное окно по центру приложения с затемнением: заголовок по центру, крестик
// закрытия, ширина и высота — по окну приложения (длинное содержимое прокручивается).
// Открывается поверх всего (Overlay), даже если объявлено внутри бокового меню.
Popup {
    id: sheet
    property string title
    property int preferredWidth: 460
    property bool closable: true
    default property alias content: body.data
    parent: Overlay.overlay
    modal: true
    focus: true
    // окно приложения (parent появляется не сразу)
    readonly property real hostWidth: parent ? parent.width : 800
    readonly property real hostHeight: parent ? parent.height : 600
    x: Math.round((hostWidth - width) / 2)
    y: Math.round((hostHeight - height) / 2)
    width: Math.min(preferredWidth, hostWidth - 32)
    height: Math.min(implicitHeight, hostHeight - 48)
    padding: 20
    topPadding: 16
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.45)
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 150 } NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 170; easing.type: Easing.OutCubic } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 110 } NumberAnimation { property: "scale"; to: 0.97; duration: 110 } }
    background: Rectangle { radius: 18; color: Ui.c.background; border.color: Qt.rgba(0.5, 0.5, 0.5, 0.2) }
    contentItem: Column {
        spacing: 14
        // заголовок строго по центру; крестик справа не сдвигает его
        Item {
            width: parent.width
            height: Math.max(titleText.implicitHeight, sheet.closable ? 32 : 0)
            visible: sheet.title.length > 0 || sheet.closable
            Text {
                id: titleText
                anchors.centerIn: parent
                width: parent.width - 80
                text: sheet.title
                color: Ui.c.textPrimary
                font.pixelSize: 18
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
            IconButton {
                visible: sheet.closable
                anchors.right: parent.right
                anchors.rightMargin: -6
                anchors.verticalCenter: parent.verticalCenter
                size: 32
                glyph: "✕"
                onClicked: sheet.close()
            }
        }
        Flickable {
            id: scroller
            width: parent.width
            // высота окна ограничена окном приложения — остальное прокручивается
            height: Math.min(body.implicitHeight, sheet.hostHeight - 48 - sheet.topPadding - sheet.bottomPadding - 14
                             - (titleText.parent.visible ? titleText.parent.height : 0))
            contentHeight: body.implicitHeight
            clip: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: scroller.contentHeight > scroller.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
            Column { id: body; width: scroller.width; spacing: 12 }
        }
    }
}
