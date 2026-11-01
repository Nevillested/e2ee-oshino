import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import Oshinobu.Core
import Qt5Compat.GraphicalEffects

// Одно сообщение ленты: пузырь по типу, статус, реакции, меню по правому клику.
Item {
    id: root
    property bool flash: false
    signal replyRequested(string id, string preview)
    signal editRequested(string id, string text)
    signal deleteRequested(string id, bool mine)
    signal forwardRequested(string text)
    signal saveRequested(string id, string name)
    signal replyClicked(string id)
    signal stickerClicked(string stickerId)

    readonly property bool mine: model.mine
    readonly property bool bare: model.kind === "sticker" || model.kind === "videoNote"
    readonly property bool centered: model.kind === "call" || model.kind === "undecryptable"
    readonly property color fg: mine ? Ui.c.onBubbleMine : Ui.c.textPrimary
    readonly property real maxBubble: Math.min(width * 0.72, 520)

    implicitHeight: bubble.height + (reactions.visible ? reactions.height + 2 : 0) + 4

    Component.onCompleted: {
        if ((model.kind === "photo" || model.kind === "voice") && model.mediaPath === "") App.downloadMedia(model.messageId)
        if (model.kind === "videoNote" && model.videoPath === "") App.downloadMedia(model.messageId)
    }

    Rectangle {
        id: bubble
        x: root.centered ? (root.width - width) / 2 : root.mine ? root.width - width - 12 : 12
        width: content.width + (root.bare ? 0 : 24)
        height: content.implicitHeight + (root.bare ? 0 : 16)
        radius: 16
        color: root.bare ? "transparent" : root.centered ? Qt.rgba(0, 0, 0, 0.25) : root.mine ? Ui.c.bubbleMine : Ui.c.surface
        border.width: root.flash ? 2 : 0
        border.color: Ui.c.primary

        Column {
            id: content
            x: root.bare ? 0 : 12
            y: root.bare ? 0 : 8
            readonly property real inner: root.maxBubble - 24
            // естественная ширина содержимого — из размеров детей без переноса (не из своей ширины)
            width: root.bare ? Math.max(model.kind === "videoNote" ? noteBox.implicitWidth : stickerBox.implicitWidth, timeRow.implicitWidth) : Math.min(inner, Math.max(
                textBody.visible ? textBody.naturalWidth : 0,
                quoteBox.visible ? quote.implicitWidth + 16 : 0,
                photoBox.visible ? photoBox.width : 0,
                fileRow.visible ? fileRow.implicitWidth : 0,
                voiceRow.visible ? voiceRow.implicitWidth : 0,
                callText.visible ? callText.implicitWidth : 0,
                stepText.visible ? stepText.implicitWidth : 0,
                timeRow.visible ? timeRow.implicitWidth : 0))
            spacing: 4

            // цитата
            Rectangle {
                id: quoteBox
                visible: model.replyToId.length > 0
                width: parent.width
                height: quote.implicitHeight + 8
                radius: 6
                color: Qt.rgba(0, 0, 0, 0.12)
                Rectangle { width: 3; height: parent.height; radius: 2; color: root.mine ? Ui.c.onBubbleMine : Ui.c.primary }
                Text {
                    id: quote
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 14
                    text: model.replyPreview
                    color: root.fg
                    opacity: 0.85
                    elide: Text.ElideRight
                    font.pixelSize: 13
                }
                MouseArea { anchors.fill: parent; onClicked: root.replyClicked(model.replyToId) }
            }

            // фото
            Item {
                id: photoBox
                visible: model.kind === "photo"
                width: Math.min(root.maxBubble - 24, 360)
                height: photo.status === Image.Ready ? Math.min(420, width * photo.implicitHeight / Math.max(1, photo.implicitWidth)) : 200
                Image {
                    id: photo
                    anchors.fill: parent
                    source: model.kind === "photo" ? model.mediaPath : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    sourceSize.width: 720
                }
                Rectangle {
                    anchors.fill: parent
                    visible: photo.status !== Image.Ready
                    radius: 10
                    color: Qt.rgba(0, 0, 0, 0.2)
                    Text { anchors.centerIn: parent; text: model.progress >= 0 ? Math.round(model.progress) + "%" : "📷"; color: root.fg; font.pixelSize: 18 }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: App.openMedia(model.messageId) }
            }

            // видео и файл
            RowLayout {
                id: fileRow
                visible: model.kind === "video" || model.kind === "file"
                spacing: 10
                Rectangle {
                    implicitWidth: 44
                    implicitHeight: 44
                    radius: 22
                    color: root.mine ? Qt.rgba(1, 1, 1, 0.25) : Ui.c.primary
                    readonly property bool showProgress: model.progress >= 0 && model.status !== "sending"
                    PlayGlyph { anchors.centerIn: parent; width: 16; height: 16; visible: !parent.showProgress && model.kind !== "file" }
                    Text {
                        anchors.centerIn: parent
                        visible: parent.showProgress || model.kind === "file"
                        text: parent.showProgress ? Math.round(model.progress) + "%" : "📄"
                        color: "white"
                        font.pixelSize: parent.showProgress ? 12 : 18
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: App.openMedia(model.messageId) }
                }
                ColumnLayout {
                    spacing: 2
                    Text {
                        text: model.fileName.length > 0 ? model.fileName : model.kind === "videoNote" ? Ui.t("media_videoNote") : Ui.t("media_video")
                        color: root.fg
                        font.pixelSize: 14
                        elide: Text.ElideMiddle
                        Layout.maximumWidth: root.maxBubble - 90
                    }
                    Text { text: model.fileSize; color: root.fg; opacity: 0.7; font.pixelSize: 12 }
                }
            }

            // видео-кружок, как на Android: круг с превью, нажатие — играет прямо в круге со звуком
            Item {
                id: noteBox
                visible: model.kind === "videoNote"
                implicitWidth: 220
                implicitHeight: 220
                readonly property bool playing: notePlayer.playbackState === MediaPlayer.PlayingState
                // плеер получает файл только по первому нажатию: в Qt 6.2 каждый плеер с файлом
                // собирает конвейер GStreamer в главном потоке — лента открывалась секундами
                property bool armed: false
                MediaPlayer {
                    id: notePlayer
                    source: noteBox.armed ? model.videoPath : ""
                    audioOutput: AudioOutput {}
                    videoOutput: noteView.videoSink
                    onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState) position = 0
                }
                // круг рисуется без масок-слоёв: VideoOutput в Qt 6.2 под слоем не показывает кадры
                Rectangle { anchors.fill: parent; radius: width / 2; color: "#202124" }
                Image {
                    id: notePreview
                    anchors.fill: parent
                    visible: !noteView.hasFrame
                    source: model.kind === "videoNote" && model.mediaPath !== model.videoPath ? model.mediaPath : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    layer.enabled: true
                    layer.effect: OpacityMask { maskSource: Rectangle { width: noteBox.width; height: noteBox.height; radius: width / 2 } }
                }
                VideoView {
                    id: noteView
                    anchors.fill: parent
                    radius: width / 2
                }
                // кольцо прогресса
                Canvas {
                    anchors.fill: parent
                    visible: notePlayer.position > 0
                    property real progress: notePlayer.duration > 0 ? notePlayer.position / notePlayer.duration : 0
                    onProgressChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.lineWidth = 4
                        ctx.lineCap = "round"
                        ctx.strokeStyle = Ui.c.primary
                        ctx.beginPath()
                        ctx.arc(width / 2, height / 2, width / 2 - 3, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * progress)
                        ctx.stroke()
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    visible: !noteBox.playing
                    width: 52; height: 52; radius: 26
                    color: Qt.rgba(0, 0, 0, 0.45)
                    PlayGlyph { anchors.centerIn: parent; width: 20; height: 20; visible: model.videoPath !== "" }
                    Text {
                        anchors.centerIn: parent
                        visible: model.videoPath === ""
                        text: model.progress >= 0 ? Math.round(model.progress) + "%" : "↓"
                        color: "white"
                        font.pixelSize: model.progress >= 0 ? 14 : 22
                    }
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 14
                    radius: 9
                    color: Qt.rgba(0, 0, 0, 0.45)
                    width: noteTime.implicitWidth + 12
                    height: noteTime.implicitHeight + 4
                    Text {
                        id: noteTime
                        anchors.centerIn: parent
                        color: "white"
                        font.pixelSize: 11
                        text: {
                            if (notePlayer.position <= 0) return model.duration
                            const s = Math.floor(notePlayer.position / 1000)
                            return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (model.videoPath === "") { App.downloadMedia(model.messageId); return }
                        noteBox.armed = true
                        noteBox.playing ? notePlayer.pause() : notePlayer.play()
                    }
                }
            }

            // голосовое
            RowLayout {
                id: voiceRow
                visible: model.kind === "voice"
                spacing: 10
                property bool armed: false // см. кружок: плеер — по первому нажатию
                MediaPlayer {
                    id: voice
                    source: voiceRow.armed ? model.mediaPath : ""
                    audioOutput: AudioOutput {}
                }
                Rectangle {
                    implicitWidth: 40
                    implicitHeight: 40
                    radius: 20
                    color: root.mine ? Qt.rgba(1, 1, 1, 0.25) : Ui.c.primary
                    PlayGlyph { anchors.centerIn: parent; width: 14; height: 14; paused: voice.playbackState === MediaPlayer.PlayingState }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (model.mediaPath === "") { App.downloadMedia(model.messageId); return }
                            voiceRow.armed = true
                            voice.playbackState === MediaPlayer.PlayingState ? voice.pause() : voice.play()
                        }
                    }
                }
                ColumnLayout {
                    spacing: 3
                    Rectangle {
                        implicitWidth: 150
                        implicitHeight: 4
                        radius: 2
                        color: Qt.rgba(0.5, 0.5, 0.5, 0.35)
                        Rectangle {
                            height: parent.height
                            radius: 2
                            width: voice.duration > 0 ? parent.width * voice.position / voice.duration : 0
                            color: root.mine ? Ui.c.onBubbleMine : Ui.c.primary
                        }
                    }
                    Text { text: model.duration; color: root.fg; opacity: 0.75; font.pixelSize: 12 }
                }
            }

            // стикер — в своих пропорциях, как на Android: длинная сторона 200, вторая — по оригиналу
            Item {
                id: stickerBox
                visible: model.kind === "sticker"
                readonly property int side: 200
                implicitWidth: stickerView.aspect < 1 ? Math.round(side * stickerView.aspect) : side
                implicitHeight: stickerView.aspect > 1 ? Math.round(side / stickerView.aspect) : side
                StickerView {
                    id: stickerView
                    anchors.fill: parent
                    source: model.kind === "sticker" ? model.stickerPath : ""
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stickerClicked(model.stickerId)
                }
            }

            // звонок / не расшифровалось
            Text {
                id: callText
                visible: root.centered
                text: model.kind === "call" ? "📞 " + model.callText : "🔒 " + Ui.t("chat_undecryptable")
                color: "white"
                font.pixelSize: 13
                wrapMode: Text.Wrap
                width: Math.min(implicitWidth, root.maxBubble)
            }

            // текст (и подпись)
            TextEdit {
                id: textBody
                visible: model.text.length > 0 && !root.centered
                // ширина строки без переноса — для ширины пузыря
                readonly property real naturalWidth: metrics.advanceWidth + 4
                width: parent.width
                text: model.text
                color: root.fg
                font.pixelSize: 15
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                selectionColor: root.mine ? Qt.rgba(1, 1, 1, 0.4) : Ui.c.primary
                textFormat: TextEdit.PlainText
                TextMetrics { id: metrics; font: textBody.font; text: model.text.split("\n").reduce((a, b) => a.length > b.length ? a : b, "") }
            }

            // этап отправки вложения
            Text {
                id: stepText
                visible: model.status === "sending" && model.step.length > 0
                text: model.step + (model.progress >= 0 ? " " + Math.round(model.progress) + "%" : "")
                color: root.fg
                opacity: 0.75
                font.pixelSize: 12
            }

            // время и статус; под стикером — на плашке, как на Android (иначе не видно на обоях)
            Rectangle {
                visible: !root.centered
                anchors.right: parent.right
                width: timeRow.implicitWidth + (root.bare ? 14 : 0)
                height: timeRow.implicitHeight + (root.bare ? 4 : 0)
                radius: 10
                color: root.bare ? Qt.rgba(Ui.c.surface.r, Ui.c.surface.g, Ui.c.surface.b, 0.85) : "transparent"
                Row {
                    id: timeRow
                    anchors.centerIn: parent
                    spacing: 4
                    Text { visible: model.edited; text: "✎"; color: root.bare ? Ui.c.textMuted : root.fg; opacity: 0.7; font.pixelSize: 11 }
                    Text { text: model.time; color: root.bare ? Ui.c.textMuted : root.fg; opacity: 0.7; font.pixelSize: 11 }
                    Ticks {
                        visible: root.mine && (model.status === "read" || model.status === "sent")
                        anchors.verticalCenter: parent.verticalCenter
                        read: model.status === "read"
                        color: model.status === "read" ? Ui.c.sentTick : (root.bare ? Ui.c.textMuted : root.fg)
                    }
                    Text {
                        visible: root.mine && model.status !== "read" && model.status !== "sent"
                        text: model.status === "failed" ? "⚠" : "🕓"
                        color: model.status === "failed" ? "#FF8A80" : (root.bare ? Ui.c.textMuted : root.fg)
                        font.pixelSize: 11
                    }
                }
            }
        }

        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: menu.popup()
        }
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: App.react(model.messageId, "👍")
        }
    }

    // реакции под пузырём
    Row {
        id: reactions
        visible: model.myReaction.length > 0 || model.peerReaction.length > 0
        anchors.top: bubble.bottom
        anchors.topMargin: -6
        x: root.mine ? bubble.x + bubble.width - width - 6 : bubble.x + 6
        spacing: 2
        Rectangle {
            radius: 11
            height: 22
            width: rtext.implicitWidth + 12
            color: Ui.c.surface
            border.color: Qt.rgba(0.5, 0.5, 0.5, 0.3)
            Text {
                id: rtext
                anchors.centerIn: parent
                text: model.peerReaction === model.myReaction ? model.myReaction + " 2" : model.myReaction + model.peerReaction
                font.pixelSize: 13
                color: Ui.c.textPrimary
            }
        }
    }

    AppMenu {
        id: menu
        Row {
            padding: 6
            spacing: 2
            Repeater {
                model: ["👍", "❤️", "😂", "😮", "😢", "🔥"]
                delegate: AbstractButton {
                    width: 34
                    height: 34
                    contentItem: Text { text: modelData; font.pixelSize: 20; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 17; color: parent.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.2) : "transparent" }
                    onClicked: { App.react(model.messageId, modelData); menu.close() }
                }
            }
        }
        AppMenuSeparator {}
        AppMenuItem { text: Ui.t("action_reply"); visible: !root.centered; height: visible ? implicitHeight : 0; onTriggered: root.replyRequested(model.messageId, model.text.length ? model.text : App.decodePreview("")) }
        AppMenuItem { text: Ui.t("action_copy"); visible: model.text.length > 0; height: visible ? implicitHeight : 0; onTriggered: App.copyText(model.text) }
        AppMenuItem { text: Ui.t("action_edit"); visible: root.mine && model.kind === "text"; height: visible ? implicitHeight : 0; onTriggered: root.editRequested(model.messageId, model.text) }
        AppMenuItem { text: Ui.t("action_pin"); visible: !root.centered; height: visible ? implicitHeight : 0; onTriggered: App.pinMessage(model.messageId, true) }
        AppMenuItem { text: Ui.t("action_forward"); visible: model.kind === "text"; height: visible ? implicitHeight : 0; onTriggered: root.forwardRequested(model.text) }
        AppMenuItem {
            text: Ui.t("chat_saveToDevice")
            visible: model.kind === "photo" || model.kind === "video" || model.kind === "file" || model.kind === "voice"
            height: visible ? implicitHeight : 0
            onTriggered: root.saveRequested(model.messageId, model.fileName.length ? model.fileName : model.kind === "voice" ? "voice.m4a" : "file")
        }
        AppMenuItem { text: Ui.t("action_retrySend"); visible: root.mine && model.status === "failed"; height: visible ? implicitHeight : 0; onTriggered: App.retry(model.messageId) }
        AppMenuItem { text: Ui.t("action_cancelSend"); visible: root.mine && model.status === "sending"; height: visible ? implicitHeight : 0; onTriggered: App.cancelSend(model.messageId) }
        AppMenuItem { text: Ui.t("action_delete"); onTriggered: root.deleteRequested(model.messageId, root.mine) }
    }
}
