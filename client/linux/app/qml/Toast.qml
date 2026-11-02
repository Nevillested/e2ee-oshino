import QtQuick

// Короткое сообщение внизу окна.
Rectangle {
    id: toast
    property alias text: label.text
    property bool isError: false
    radius: 18
    color: isError ? "#C62828" : Qt.rgba(0.1, 0.1, 0.12, 0.92)
    width: Math.min(label.implicitWidth + 36, parent ? parent.width - 40 : 400)
    height: label.implicitHeight + 20
    opacity: 0
    visible: opacity > 0
    function show(message, error) {
        text = message
        isError = !!error
        opacity = 1
        // обычное — 2 с и мягко гаснет; ошибку держим дольше
        hide.interval = isError ? 3200 : 2000
        hide.restart()
    }
    Behavior on opacity { NumberAnimation { duration: toast.opacity > 0.5 ? 400 : 180 } }
    transform: Translate { y: toast.opacity < 1 ? (1 - toast.opacity) * 16 : 0 }
    Text {
        id: label
        anchors.centerIn: parent
        width: parent.width - 36
        color: "white"
        font.pixelSize: 14
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
    }
    Timer { id: hide; onTriggered: toast.opacity = 0 }
}
