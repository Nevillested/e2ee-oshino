import QtQuick
import QtQuick.Controls
import Oshinobu.Core

// Сетка стикеров как на Android: нажатие — отправить ([sendRequested]), долгое нажатие —
// крупное превью (App.previewSticker); не отпуская кнопку, можно вести по сетке — превью
// переключается на стикер под курсором. Отпустили — превью гаснет, ничего не отправляется.
GridView {
    id: grid
    property int columns: 5
    property bool canSend: true
    signal sendRequested(var sticker)

    clip: true
    cellWidth: Math.floor(width / columns)
    cellHeight: cellWidth
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {}

    property int hoverIndex: -1
    property bool previewing: false

    function stickerAt(mx, my) {
        const i = indexAt(mx + contentX, my + contentY)
        return i >= 0 && i < count ? { index: i, sticker: model[i] } : null
    }

    delegate: Item {
        width: grid.cellWidth
        height: grid.cellHeight
        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 12
            color: index === grid.hoverIndex && !grid.previewing ? Qt.rgba(0.5, 0.5, 0.5, 0.15) : "transparent"
            Behavior on color { ColorAnimation { duration: 90 } }
        }
        StickerView {
            anchors.fill: parent
            anchors.margins: 6
            source: App.stickerUrl(modelData.id, App.stickerRevision)
            scale: grid.previewing && App.previewSticker === modelData.id ? 0.85 : 1
            Behavior on scale { NumberAnimation { duration: 120 } }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        pressAndHoldInterval: 350
        onPositionChanged: (mouse) => {
            const hit = grid.stickerAt(mouse.x, mouse.y)
            grid.hoverIndex = hit ? hit.index : -1
            if (grid.previewing && hit) App.previewSticker = hit.sticker.id
        }
        onExited: if (!pressed) grid.hoverIndex = -1
        onPressAndHold: (mouse) => {
            const hit = grid.stickerAt(mouse.x, mouse.y)
            if (!hit) return
            grid.previewing = true
            App.previewSticker = hit.sticker.id
        }
        onReleased: {
            if (grid.previewing) {
                grid.previewing = false
                App.previewSticker = ""
            }
        }
        onCanceled: { grid.previewing = false; App.previewSticker = "" }
        onClicked: (mouse) => {
            if (grid.previewing || !grid.canSend) return
            const hit = grid.stickerAt(mouse.x, mouse.y)
            if (hit) grid.sendRequested(hit.sticker)
        }
        // колесо — прокрутке сетки (MouseArea поверх его бы съел)
        onWheel: (wheel) => grid.flick(0, wheel.angleDelta.y * 8)
    }
}
