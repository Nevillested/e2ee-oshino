import QtQuick

// «Таблетка» шапки чата и пузырь поля ввода, как на Android: скругление и мягкая тень,
// висит над обоями чата.
Item {
    id: root
    default property alias content: box.data
    property real radius: height / 2
    property color color: Ui.c.surface
    // размер задаёт тот, кто ставит (содержимое растянуто по таблетке — иначе петля)
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2
        anchors.bottomMargin: -2
        radius: root.radius
        color: Qt.rgba(0, 0, 0, 0.22)
    }
    Rectangle {
        id: box
        anchors.fill: parent
        radius: root.radius
        color: root.color
        border.color: Qt.rgba(0.5, 0.5, 0.5, 0.12)
    }
}
