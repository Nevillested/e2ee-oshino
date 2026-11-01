import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Oshinobu.Core

// Превью обоев на весь чат, как на Android: картинку двигают и масштабируют, ставится видимая часть.
Item {
    id: root
    property url file
    property bool busy: false
    visible: opacity > 0
    opacity: file.toString().length > 0 ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    clip: true

    // масштаб «заполнить» × увеличение пользователя (до 5×, как на Android)
    property real zoom: 1
    readonly property real cover: img.sourceSize.width > 0 ? Math.max(width / img.sourceSize.width, height / img.sourceSize.height) : 1
    readonly property real k: cover * zoom

    property bool needsCenter: false
    function open(url) {
        zoom = 1
        busy = false
        needsCenter = true
        file = url
    }
    function close() { file = "" }
    function clampPos() {
        img.x = Math.min(0, Math.max(width - img.width, img.x))
        img.y = Math.min(0, Math.max(height - img.height, img.y))
    }
    // размер картинки известен не сразу после Ready — центрируем, когда он появился
    function centerIfNeeded() {
        if (!needsCenter || img.status !== Image.Ready || img.width <= 0) return
        needsCenter = false
        img.x = (width - img.width) / 2
        img.y = (height - img.height) / 2
    }
    // масштаб вокруг точки (px, py) окна превью
    function zoomAt(f, px, py) {
        const z = Math.max(1, Math.min(5, zoom * f))
        const r = z / zoom
        zoom = z
        img.x = px - (px - img.x) * r
        img.y = py - (py - img.y) * r
        clampPos()
    }

    onWidthChanged: clampPos()
    onHeightChanged: clampPos()

    Rectangle { anchors.fill: parent; color: "black" }

    Image {
        id: img
        source: root.file
        asynchronous: true
        smooth: true
        mipmap: true
        width: sourceSize.width * root.k
        height: sourceSize.height * root.k
        onStatusChanged: {
            if (status === Image.Error) {
                App.error(Ui.t("error_wallpaperFailed")) // сигнал App — тост с ошибкой
                root.close()
            }
            root.centerIfNeeded()
        }
        onWidthChanged: root.centerIfNeeded()
        onHeightChanged: root.centerIfNeeded()
    }

    DragHandler {
        target: img
        enabled: !root.busy
        onActiveChanged: if (!active) root.clampPos()
        xAxis.minimum: root.width - img.width
        xAxis.maximum: 0
        yAxis.minimum: root.height - img.height
        yAxis.maximum: 0
    }
    WheelHandler {
        enabled: !root.busy
        onWheel: (e) => root.zoomAt(Math.pow(1.0015, e.angleDelta.y), e.x, e.y)
    }
    PinchHandler {
        target: null
        enabled: !root.busy
        property real last: 1
        onActiveChanged: last = 1
        onActiveScaleChanged: { root.zoomAt(activeScale / last, centroid.position.x, centroid.position.y); last = activeScale }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 16
        radius: height / 2
        color: Qt.rgba(0, 0, 0, 0.55)
        width: hint.implicitWidth + 28
        height: hint.implicitHeight + 14
        Text { id: hint; anchors.centerIn: parent; text: Ui.t("linux_wallpaperHint"); color: "white"; font.pixelSize: 13 }
    }

    // компактная карточка по центру снизу: флажок и кнопки — по центру карточки
    Rectangle {
        id: card
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 20
        width: Math.min(cardCol.implicitWidth + 32, root.width - 32)
        height: cardCol.implicitHeight + 24
        radius: 18
        color: Ui.c.background
        border.color: Qt.rgba(0.5, 0.5, 0.5, 0.2)
        transform: Translate { y: root.opacity < 1 ? (1 - root.opacity) * 40 : 0 }
        Column {
            id: cardCol
            anchors.centerIn: parent
            spacing: 8
            ThemedCheck {
                id: both
                anchors.horizontalCenter: parent.horizontalCenter
                text: Ui.t("chat_wallpaperAlsoFor") + " " + App.openChat
                checked: true
                enabled: !root.busy
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                FlatButton { text: Ui.t("common_cancel"); primary: false; enabled: !root.busy; onClicked: root.close() }
                FlatButton {
                    text: root.busy ? "" : Ui.t("chat_wallpaperSet")
                    enabled: !root.busy && img.status === Image.Ready
                    BusyIndicator { anchors.centerIn: parent; running: root.busy; visible: running; implicitWidth: 28; implicitHeight: 28 }
                    onClicked: {
                        root.busy = true
                        App.setWallpaper(root.file, both.checked,
                                         -img.x / img.width, -img.y / img.height,
                                         root.width / img.width, root.height / img.height)
                    }
                }
            }
        }
    }

    Connections {
        target: App
        function onWallpaperDone(ok) {
            root.busy = false
            if (ok) root.close()
        }
        function onOpenChatChanged() { if (!root.busy) root.close() }
    }
}
