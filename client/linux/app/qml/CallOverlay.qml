import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Oshinobu.Core

// Экран звонка поверх приложения: входящий — принять/отклонить; в разговоре — таймер,
// микрофон, камера, выбор микрофона и вывода, завершение. Видео собеседника — на весь
// экран, своё — окошком в углу (как на Android).
Rectangle {
    id: overlay
    color: Ui.c.background
    MouseArea { anchors.fill: parent; hoverEnabled: true }

    readonly property bool remoteVideoShown: App.call.remoteVideo === true && remote.hasFrame
    readonly property bool localVideoShown: App.call.video === true && local.hasFrame

    component RoundButton: AbstractButton {
        id: rb
        property color fill
        property string glyph
        property string tip
        implicitWidth: 64
        implicitHeight: 64
        hoverEnabled: true
        scale: down ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: 90 } }
        contentItem: Text { text: rb.glyph; color: "white"; font.pixelSize: 26; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle {
            radius: width / 2
            color: rb.fill
            opacity: rb.down ? 0.8 : rb.hovered ? 0.92 : 1
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        ToolTip.visible: tip.length > 0 && hovered
        ToolTip.text: tip
        ToolTip.delay: 600
    }

    // видео собеседника
    VideoView {
        id: remote
        anchors.fill: parent
        local: false
        opacity: overlay.remoteVideoShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 18
        opacity: overlay.remoteVideoShown ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 220 } }
        Avatar {
            Layout.alignment: Qt.AlignHCenter
            size: 140
            name: App.call.peer || "?"
            source: Ui.avatar(App.call.accountId)
        }
        Text { text: App.call.peer || ""; color: Ui.c.textPrimary; font.pixelSize: 28; font.bold: true; Layout.alignment: Qt.AlignHCenter }
    }

    // статус / таймер — сверху, читается и поверх видео
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: overlay.remoteVideoShown ? 20 : parent.height / 2 + 120
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        radius: height / 2
        color: overlay.remoteVideoShown ? Qt.rgba(0, 0, 0, 0.5) : "transparent"
        width: statusLine.implicitWidth + 28
        height: statusLine.implicitHeight + 12
        Text {
            id: statusLine
            anchors.centerIn: parent
            color: overlay.remoteVideoShown ? "white" : Ui.c.textMuted
            font.pixelSize: 17
            property int tick: 0
            text: {
                tick
                const peer = overlay.remoteVideoShown ? (App.call.peer || "") + " · " : ""
                if (App.call.connectedAt > 0) {
                    const s = Math.max(0, Math.floor((Date.now() - App.call.connectedAt) / 1000))
                    return peer + Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
                }
                return peer + (App.call.status || (App.call.state === "incoming" ? Ui.t("call_incoming") : ""))
            }
            Timer { interval: 1000; repeat: true; running: App.call.connectedAt > 0; onTriggered: statusLine.tick++ }
        }
    }

    // своё видео — окошко в углу
    Rectangle {
        id: localBox
        visible: opacity > 0
        opacity: overlay.localVideoShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 20
        width: 200
        height: 150
        radius: 14
        color: "black"
        clip: true
        VideoView { id: local; anchors.fill: parent; local: true }
        Text {
            anchors.centerIn: parent
            visible: App.call.video === true && !local.hasFrame
            text: Ui.t("call_connecting")
            color: "white"
            font.pixelSize: 12
        }
    }

    RowLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 48
        spacing: 60
        visible: App.call.state === "incoming"
        RoundButton { glyph: "✕"; fill: "#E5534B"; onClicked: App.declineCall() }
        RoundButton { glyph: "📞"; fill: "#2EA043"; onClicked: App.acceptCall() }
    }
    RowLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 48
        spacing: 24
        visible: App.call.state !== "incoming"
        RoundButton {
            glyph: App.call.mic ? "🎤" : "🔇"
            tip: Ui.t("linux_callMicrophone")
            fill: App.call.mic ? Qt.rgba(0.5, 0.5, 0.5, 0.35) : Ui.c.primary
            onClicked: App.toggleMic()
        }
        RoundButton {
            visible: App.call.hasCamera === true
            glyph: "📷"
            tip: Ui.t("linux_callCamera")
            fill: App.call.video ? Ui.c.primary : Qt.rgba(0.5, 0.5, 0.5, 0.35)
            enabled: App.call.state === "connected"
            onClicked: App.toggleVideo()
        }
        RoundButton {
            id: devicesButton
            glyph: "🎧"
            tip: Ui.t("linux_callDevices")
            fill: Qt.rgba(0.5, 0.5, 0.5, 0.35)
            onClicked: devicesMenu.show()
        }
        RoundButton { glyph: "✕"; tip: Ui.t("call_endAction"); fill: "#E5534B"; onClicked: App.hangUp() }
    }

    // выбор микрофона и вывода — список устройств опрашивается при каждом открытии
    Popup {
        id: devicesMenu
        property var inputs: []
        property var outputs: []
        function show() {
            inputs = App.audioDevices(true)
            outputs = App.audioDevices(false)
            const p = devicesButton.mapToItem(overlay, 0, 0)
            x = Math.max(12, Math.min(overlay.width - width - 12, p.x + devicesButton.width / 2 - width / 2))
            open()
            y = p.y - height - 12
        }
        width: 340
        padding: 8
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        enter: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { property: "scale"; from: 0.94; to: 1; duration: 160; easing.type: Easing.OutCubic }
        }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 110 } }
        background: Rectangle { radius: 14; color: Ui.c.surface; border.color: Qt.rgba(0.5, 0.5, 0.5, 0.18) }

        component DeviceRow: ItemDelegate {
            id: row
            property var device
            property bool input
            width: parent ? parent.width : 0
            implicitHeight: 40
            leftPadding: 12
            rightPadding: 12
            contentItem: RowLayout {
                spacing: 10
                Text { text: "✓"; color: Ui.c.primary; font.pixelSize: 15; font.bold: true; opacity: row.device.current ? 1 : 0; Layout.preferredWidth: 14 }
                Text { text: row.device.name; color: Ui.c.textPrimary; font.pixelSize: 14; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            background: Rectangle {
                radius: 9
                color: row.hovered ? Qt.rgba(Ui.c.primary.r, Ui.c.primary.g, Ui.c.primary.b, 0.16) : "transparent"
                Behavior on color { ColorAnimation { duration: 90 } }
            }
            onClicked: {
                App.selectAudioDevice(input, device.id)
                devicesMenu.close()
            }
        }

        contentItem: Column {
            spacing: 2
            Text { text: Ui.t("linux_callMicrophone"); color: Ui.c.textMuted; font.pixelSize: 12; font.bold: true; leftPadding: 12; topPadding: 6; bottomPadding: 4 }
            Repeater { model: devicesMenu.inputs; delegate: DeviceRow { device: modelData; input: true } }
            Text { visible: devicesMenu.inputs.length === 0; text: Ui.t("linux_callNoDevices"); color: Ui.c.textMuted; font.pixelSize: 13; leftPadding: 12 }
            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0.5, 0.5, 0.5, 0.18) }
            Text { text: Ui.t("linux_callSpeaker"); color: Ui.c.textMuted; font.pixelSize: 12; font.bold: true; leftPadding: 12; topPadding: 6; bottomPadding: 4 }
            Repeater { model: devicesMenu.outputs; delegate: DeviceRow { device: modelData; input: false } }
            Text { visible: devicesMenu.outputs.length === 0; text: Ui.t("linux_callNoDevices"); color: Ui.c.textMuted; font.pixelSize: 13; leftPadding: 12 }
        }
    }
}
