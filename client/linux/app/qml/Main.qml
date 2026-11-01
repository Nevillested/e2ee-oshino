import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Oshinobu.Core

ApplicationWindow {
    id: window
    width: 1120
    height: 740
    minimumWidth: 760
    minimumHeight: 520
    visible: true
    title: "Oshinobu"
    color: Ui.c.background
    // всплывающие подсказки стиля Basic — в цветах темы
    palette.toolTipBase: Ui.c.surface
    palette.toolTipText: Ui.c.textPrimary

    onActiveChanged: App.setWindowActive(active)

    // смена экрана (заставка → вход → чаты) — плавно
    Loader {
        id: screen
        anchors.fill: parent
        sourceComponent: App.phase === "signedIn" ? home : App.phase === "signedOut" ? auth : splash
        onLoaded: { item.opacity = 0; fadeIn.restart() }
        NumberAnimation { id: fadeIn; target: screen.item; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
    }

    Component {
        id: splash
        Item {
            Image {
                anchors.centerIn: parent
                source: "qrc:/qt/qml/Oshinobu/icons/oshinobu.png"
                width: 96
                height: 96
            }
        }
    }
    Component { id: auth; AuthFlow {} }
    Component { id: home; HomeView {} }

    LockScreen {
        anchors.fill: parent
        visible: App.locked
        z: 100
    }

    StickerPreview {}

    CallOverlay {
        anchors.fill: parent
        visible: App.call.state !== "idle"
        z: 90
    }

    Toast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 90
        z: 200
    }

    Connections {
        target: App
        function onError(text) { toast.show(text, true) }
        function onInfo(text) { toast.show(text, false) }
        function onRaiseRequested() { window.show(); window.raise(); window.requestActivate() }
    }
}
