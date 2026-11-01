import QtQuick

// Текст, который сменяется плавно: старый уходит вверх и гаснет, новый появляется снизу.
Item {
    id: root
    property string text
    property color color
    property int pixelSize: 13
    property int horizontalAlignment: Text.AlignLeft
    implicitHeight: a.implicitHeight
    implicitWidth: Math.max(a.implicitWidth, b.implicitWidth)
    clip: true
    property bool showA: true
    // смена без анимации (другой чат): старый текст не должен проступать в новом
    property bool snapping: false
    function snap() {
        snapping = true
        snapTimer.restart()
    }
    Timer { id: snapTimer; interval: 150; onTriggered: root.snapping = false }
    onTextChanged: {
        if (snapping) {
            a.text = text
            b.text = ""
            showA = true
            return
        }
        const next = showA ? b : a
        next.text = text
        showA = !showA
    }
    Text {
        id: a
        width: root.width
        color: root.color
        font.pixelSize: root.pixelSize
        elide: Text.ElideRight
        horizontalAlignment: root.horizontalAlignment
        opacity: root.showA ? 1 : 0
        y: root.showA ? 0 : -6
        Behavior on opacity { enabled: !root.snapping; NumberAnimation { duration: 220 } }
        Behavior on y { enabled: !root.snapping; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    }
    Text {
        id: b
        width: root.width
        color: root.color
        font.pixelSize: root.pixelSize
        elide: Text.ElideRight
        horizontalAlignment: root.horizontalAlignment
        opacity: root.showA ? 0 : 1
        y: root.showA ? 6 : 0
        Behavior on opacity { enabled: !root.snapping; NumberAnimation { duration: 220 } }
        Behavior on y { enabled: !root.snapping; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    }
    Component.onCompleted: a.text = text
}
