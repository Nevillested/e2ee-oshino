import QtQuick
import QtQuick.Controls
import Oshinobu.Core

// Крупное превью стикера по долгому нажатию (как на Android): затемнение и стикер 240 px
// по центру окна с упругим появлением; касаний не принимает. Живёт в слое Overlay поверх
// всех окон — иначе панель стикеров и окно пака закрывали бы его.
Item {
    id: root
    parent: Overlay.overlay
    z: 10000
    anchors.fill: parent
    readonly property bool active: App.previewSticker.length > 0
    property string shown
    onActiveChanged: if (active) shown = App.previewSticker
    Connections { target: App; function onPreviewStickerChanged() { if (App.previewSticker.length > 0) root.shown = App.previewSticker } }
    visible: dim.opacity > 0

    Rectangle {
        id: dim
        anchors.fill: parent
        color: "black"
        opacity: root.active ? 0.45 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
    }
    StickerView {
        width: 240
        height: 240
        anchors.centerIn: parent
        source: root.shown.length ? App.stickerUrl(root.shown, App.stickerRevision) : ""
        opacity: root.active ? 1 : 0
        scale: root.active ? 1 : 0.4
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Behavior on scale { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.005 } }
    }
}
