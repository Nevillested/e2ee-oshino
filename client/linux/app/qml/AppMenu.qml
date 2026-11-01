import QtQuick
import QtQuick.Controls

// Контекстное меню в цветах темы: скругление, тень, плавное появление.
Menu {
    id: menu
    padding: 6
    topPadding: 6
    bottomPadding: 6
    implicitWidth: 230
    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: 160; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 110 } }
    background: Rectangle {
        radius: 14
        color: Ui.c.surface
        border.color: Qt.rgba(0.5, 0.5, 0.5, 0.18)
        Rectangle { anchors.fill: parent; anchors.margins: -1; z: -1; radius: 15; color: Qt.rgba(0, 0, 0, 0.25); anchors.topMargin: 2 }
    }
    delegate: AppMenuItem {}
}
