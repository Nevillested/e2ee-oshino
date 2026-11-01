import QtQuick
import Oshinobu.Core

// Стикер любого формата: PNG/WebP (в т.ч. анимированный) — AnimatedImage, TGS — rlottie.
// [aspect] — ширина/высота оригинала: по нему пузырь берёт размер, как на Android.
Item {
    id: root
    property string source
    readonly property bool tgs: source.endsWith(".tgs")
    readonly property real aspect: !tgs && img.sourceSize.width > 0 && img.sourceSize.height > 0 ? img.sourceSize.width / img.sourceSize.height : 1
    AnimatedImage {
        id: img
        anchors.fill: parent
        visible: !root.tgs
        source: root.tgs ? "" : root.source
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        // оригинал 512 px в 200 px — со сглаживанием и мипмапами, иначе «рваные» края
        smooth: true
        mipmap: true
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }
    Loader {
        anchors.fill: parent
        active: root.tgs && App.tgsSupported
        source: "TgsView.qml"
        onLoaded: item.source = Qt.binding(() => root.source)
    }
    Text {
        anchors.centerIn: parent
        visible: root.source.length === 0 || (root.tgs && !App.tgsSupported)
        text: root.source.length === 0 ? "…" : "🎞"
        color: Ui.c.textMuted
        font.pixelSize: Math.min(root.width, root.height) * 0.3
    }
}
