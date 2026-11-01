import QtQuick
import Qt5Compat.GraphicalEffects

// Круглое фото профиля или первая буква логина на цветном фоне.
Item {
    id: root
    property string source
    property string name
    property int size: 40
    width: size
    height: size

    readonly property color tint: {
        const colors = ["#E57373", "#F06292", "#BA68C8", "#7986CB", "#4FC3F7", "#4DB6AC", "#81C784", "#FFB74D"]
        let h = 0
        for (let i = 0; i < name.length; ++i) h = (h * 31 + name.charCodeAt(i)) % 997
        return colors[h % colors.length]
    }

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.tint
        visible: img.status !== Image.Ready
        Text {
            anchors.centerIn: parent
            text: Ui.initials(root.name)
            color: "white"
            font.pixelSize: root.size * 0.42
            font.bold: true
        }
    }
    Image {
        id: img
        anchors.fill: parent
        source: root.source
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectCrop
        visible: false
        asynchronous: true
    }
    Rectangle {
        id: mask
        anchors.fill: parent
        radius: width / 2
        visible: false
    }
    OpacityMask {
        anchors.fill: parent
        source: img
        maskSource: mask
        visible: img.status === Image.Ready
    }
}
