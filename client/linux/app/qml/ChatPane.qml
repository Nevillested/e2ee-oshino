import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Oshinobu.Core

// Переписка с собеседником.
Item {
    id: pane
    // смена чата — переписка мягко въезжает
    opacity: 0
    Component.onCompleted: appear.start()
    // другой чат: статус и кнопка «вниз» прошлого чата не должны проступать в новом
    property bool switching: false
    Timer { id: switchTimer; interval: 300; onTriggered: pane.switching = false }
    Connections {
        target: App
        function onOpenChatChanged() {
            pane.switching = true
            switchTimer.restart()
            presenceFade.snap()
            // новый чат — с последних сообщений (высоты пузырей известны не сразу — после кадра)
            list.stickToEnd = true
            Qt.callLater(list.positionViewAtEnd)
            if (App.openChat.length > 0) appear.restart()
        }
    }
    ParallelAnimation {
        id: appear
        NumberAnimation { target: pane; property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { target: slide; property: "x"; from: 24; to: 0; duration: 260; easing.type: Easing.OutCubic }
    }
    transform: Translate { id: slide }
    property string replyToId
    property string replyPreview
    property string editingId
    readonly property var info: App.openChatInfo
    readonly property bool blocked: info.blockedByMe || info.blockingMe

    // фон: обои чата или цвет темы
    Image {
        anchors.fill: parent
        source: App.wallpaper
        fillMode: Image.PreserveAspectCrop
        visible: source.toString().length > 0
        asynchronous: true
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- шапка: три «таблетки» над обоями, как на Android ----------------
        Item {
            Layout.fillWidth: true
            implicitHeight: 64
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                spacing: 8
                // слева — передачи (назад не нужен: список чатов и так виден)
                Pill {
                    Layout.preferredHeight: centerPill.height
                    Layout.preferredWidth: centerPill.height
                    IconButton { anchors.centerIn: parent; glyph: "⇅"; tint: Ui.c.textPrimary; tip: Ui.t("transfers_title"); onClicked: transfers.open() }
                }
                // по центру — собеседник: открывает профиль
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Pill {
                        id: centerPill
                        anchors.centerIn: parent
                        width: Math.min(parent.width, peerRow.implicitWidth + 28)
                        height: 48
                        scale: peerTap.pressed ? 0.97 : 1
                        Behavior on scale { NumberAnimation { duration: 90 } }
                        RowLayout {
                            id: peerRow
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, centerPill.width - 28)
                            spacing: 10
                            Avatar { size: 34; name: App.openChat; source: Ui.avatar(info.accountId) }
                            ColumnLayout {
                                spacing: 0
                                Layout.maximumWidth: 320
                                Text {
                                    Layout.fillWidth: true
                                    text: App.openChat
                                    color: Ui.c.textPrimary
                                    font.pixelSize: 15
                                    font.bold: true
                                    elide: Text.ElideRight
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                FadeText {
                                    id: presenceFade
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: Math.max(implicitWidth, 60)
                                    horizontalAlignment: Text.AlignHCenter
                                    text: info.deleted ? Ui.t("home_deletedAccount") : App.presence
                                    color: App.presence === Ui.t("presence_online") || App.presence === Ui.t("presence_typing") ? Ui.c.primary : Ui.c.textMuted
                                    pixelSize: 12
                                }
                            }
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { id: peerTap; onTapped: { peerProfile.login = App.openChat; peerProfile.open() } }
                    }
                }
                // справа — звонок и меню
                Pill {
                    Layout.preferredHeight: centerPill.height
                    Layout.preferredWidth: actionsRow.implicitWidth + 12
                    Row {
                        id: actionsRow
                        anchors.centerIn: parent
                        IconButton { glyph: "📞"; tip: Ui.t("call_dialing"); enabled: info.hasDevice && !pane.blocked && App.call.state === "idle"; onClicked: App.startCall() }
                        IconButton { id: menuButton; glyph: "⋮"; tint: Ui.c.textPrimary; onClicked: menu.popup(menuButton, 0, menuButton.height + 6) }
                    }
                }
            }
            AppMenu {
                id: menu
                AppMenuItem { text: info.muted ? Ui.t("chatMenu_unmute") : Ui.t("chatMenu_mute"); onTriggered: App.setMuted(App.openChat, !info.muted) }
                AppMenuItem { text: info.blockedByMe ? Ui.t("chatMenu_unblock") : Ui.t("chatMenu_block"); onTriggered: App.setBlocked(App.openChat, !info.blockedByMe) }
                AppMenuItem { text: Ui.t("chat_wallpaperAction"); onTriggered: wallpaperDialog.open() }
                AppMenuItem { text: Ui.t("chat_wallpaperRemove"); enabled: App.wallpaper.length > 0; onTriggered: App.removeWallpaper() }
                AppMenuItem { text: Ui.t("chat_resetSessionAction"); onTriggered: resetSheet.open() }
                AppMenuSeparator {}
                AppMenuItem { text: Ui.t("chatMenu_clearHistory"); onTriggered: clearSheet.open() }
                AppMenuItem { text: Ui.t("chatMenu_deleteChat"); onTriggered: deleteSheet.open() }
            }
        }

        // ---------------- закреп ----------------
        Pill {
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            visible: info.pinned && info.pinned.id !== undefined
            implicitHeight: 46
            radius: 14
            Rectangle { width: 3; height: parent.height - 14; anchors.verticalCenter: parent.verticalCenter; x: 12; color: Ui.c.primary; radius: 2 }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                x: 24
                width: parent.width - 80
                Text { text: Ui.t("chat_pinnedMessage"); color: Ui.c.primary; font.pixelSize: 12; font.bold: true }
                Text { text: info.pinned ? info.pinned.text || "" : ""; color: Ui.c.textPrimary; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width }
            }
            IconButton { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; glyph: "✕"; size: 30; onClicked: App.pinMessage(info.pinned.id, false) }
            MouseArea { anchors.fill: parent; anchors.rightMargin: 40; onClicked: list.jumpTo(info.pinned.id) }
        }

        // ---------------- лента ----------------
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: App.messages
            spacing: 4
            topMargin: 10
            bottomMargin: 10
            cacheBuffer: 2000
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            property bool stickToEnd: true
            // низ ленты — с учётом originY: у ленты с разной высотой пузырей он не ноль, и старая
            // проверка считала, что мы «не внизу» всегда (кнопка «вниз» не пряталась)
            readonly property bool atEnd: contentHeight + topMargin + bottomMargin <= height
                                          || contentY + height >= originY + contentHeight + bottomMargin - 40

            onCountChanged: if (stickToEnd) Qt.callLater(positionViewAtEnd)
            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 }
                    NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
                }
            }
            remove: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; to: 0; duration: 260 }
                    NumberAnimation { property: "scale"; to: 0.85; duration: 260; easing.type: Easing.InCubic }
                }
            }
            displaced: Transition { NumberAnimation { properties: "y"; duration: 240; easing.type: Easing.OutCubic } }
            onMovementEnded: stickToEnd = atEnd
            Component.onCompleted: Qt.callLater(positionViewAtEnd)

            NumberAnimation { id: scrollAnim; target: list; property: "contentY"; duration: 450; easing.type: Easing.InOutCubic }
            function jumpTo(id) {
                const i = App.messages.indexOf(id)
                if (i < 0) return
                const from = contentY
                positionViewAtIndex(i, ListView.Center)
                const to = contentY
                contentY = from
                scrollAnim.from = from
                scrollAnim.to = to
                scrollAnim.start()
                flashId = id
            }
            property string flashId

            delegate: MessageBubble {
                width: ListView.view.width
                flash: list.flashId === model.messageId
                onReplyRequested: (id, preview) => { pane.editingId = ""; pane.replyToId = id; pane.replyPreview = preview; input.forceActiveFocus() }
                onEditRequested: (id, text) => { pane.replyToId = ""; pane.editingId = id; input.text = text; input.forceActiveFocus() }
                onDeleteRequested: (id, mine) => { deleteMsg.ids = [id]; deleteMsg.mine = mine; deleteMsg.open() }
                onForwardRequested: (text) => { forward.text = text; forward.open() }
                onSaveRequested: (id, name) => { saveDialog.messageId = id; saveDialog.currentFile = "file:///" + name; saveDialog.open() }
                onReplyClicked: (id) => list.jumpTo(id)
                onStickerClicked: (id) => packSheet.show(id)
            }

            // кнопка «вниз»: последнее сообщение ушло из вида
            Rectangle {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 14
                width: 44
                height: 44
                radius: 12
                color: Ui.c.surface
                opacity: list.atEnd || pane.switching ? 0 : 1
                visible: opacity > 0
                scale: list.atEnd ? 0.8 : 1
                Behavior on opacity { enabled: !pane.switching; NumberAnimation { duration: 160 } }
                Behavior on scale { NumberAnimation { duration: 160 } }
                // стрелка нарисована, а не символом шрифта: «⌄» сидит у шрифта выше центра
                Canvas {
                    anchors.centerIn: parent
                    width: 18
                    height: 10
                    property color stroke: Ui.c.textPrimary
                    onStrokeChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = stroke
                        ctx.lineWidth = 2.4
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        ctx.beginPath()
                        ctx.moveTo(2, 2)
                        ctx.lineTo(width / 2, height - 2)
                        ctx.lineTo(width - 2, 2)
                        ctx.stroke()
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        scrollAnim.from = list.contentY
                        scrollAnim.to = Math.max(list.originY, list.contentHeight - list.height + list.originY + list.bottomMargin)
                        scrollAnim.start()
                        list.stickToEnd = true
                    }
                }
            }
        }

        // ---------------- поле ввода ----------------
        // пузырь, а не полоса во всю ширину (как на Android)
        Pill {
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.bottomMargin: 10
            Layout.topMargin: 4
            implicitHeight: composer.implicitHeight + 12
            radius: 24
            ColumnLayout {
                id: composer
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 8
                spacing: 6

                // ответ / правка
                RowLayout {
                    visible: pane.replyToId.length > 0 || pane.editingId.length > 0
                    Layout.fillWidth: true
                    Rectangle { width: 3; Layout.fillHeight: true; color: Ui.c.primary; radius: 2 }
                    Text {
                        Layout.fillWidth: true
                        text: pane.editingId.length > 0 ? Ui.t("chat_editingMessage") : pane.replyPreview
                        color: Ui.c.textMuted
                        elide: Text.ElideRight
                    }
                    IconButton { glyph: "✕"; size: 28; onClicked: { pane.replyToId = ""; pane.editingId = ""; input.text = "" } }
                }

                Text {
                    visible: pane.blocked
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: info.blockedByMe && info.blockingMe ? Ui.t("chat_blockedMutual") : info.blockedByMe ? Ui.t("chat_blockedByMe") : Ui.t("chat_blockingMe")
                    color: Ui.c.textMuted
                    padding: 10
                }

                RowLayout {
                    visible: !pane.blocked
                    Layout.fillWidth: true
                    spacing: 4
                    IconButton { visible: !App.recording; glyph: "📎"; tip: Ui.t("media_file"); onClicked: fileDialog.open() }
                    ScrollView {
                        visible: !App.recording
                        Layout.fillWidth: true
                        Layout.maximumHeight: 160
                        TextArea {
                            id: input
                            placeholderText: Ui.t("chat_messageHint")
                            placeholderTextColor: Ui.c.textMuted
                            color: Ui.c.textPrimary
                            wrapMode: TextEdit.Wrap
                            font.pixelSize: 15
                            selectByMouse: true
                            background: null
                            focus: true
                            onTextChanged: if (text.length > 0) App.typing()
                            Keys.onReturnPressed: (event) => {
                                if (event.modifiers & Qt.ShiftModifier) { event.accepted = false; return }
                                pane.send()
                            }
                            Keys.onEscapePressed: { pane.replyToId = ""; pane.editingId = "" }
                        }
                    }
                    // идёт запись: мигающая точка и таймер (как на Android, без подсказок)
                    RowLayout {
                        visible: App.recording
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        spacing: 8
                        Rectangle {
                            width: 10; height: 10; radius: 5
                            color: "#FF5252"
                            SequentialAnimation on opacity {
                                running: App.recording
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.2; duration: 600 }
                                NumberAnimation { to: 1; duration: 600 }
                            }
                        }
                        Text {
                            text: {
                                const s = Math.floor(App.recElapsed / 1000)
                                return String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0")
                            }
                            color: Ui.c.textPrimary
                            font.family: "monospace"
                            font.pixelSize: 15
                        }
                        Item { Layout.fillWidth: true; implicitHeight: 40 }
                    }
                    IconButton { visible: !App.recording; glyph: "☺"; tip: Ui.t("sticker_tabStickers"); onClicked: stickers.open() }
                    // зафиксированная запись: отмена и отправка
                    IconButton {
                        visible: App.recState === "locked"
                        glyph: "✕"
                        tint: "#FF5252"
                        tip: Ui.t("chat_cancelRecording")
                        onClicked: App.finishRecording(false)
                    }
                    IconButton {
                        visible: App.recState === "locked"
                        glyph: "➤"
                        tint: Ui.c.primary
                        tip: Ui.t("common_send")
                        onClicked: App.finishRecording(true)
                    }
                    // кнопка записи: тап — микрофон ⇄ камера, удержание — запись, вверх на замок — фиксация
                    Item {
                        id: recButton
                        visible: App.canRecord && App.recState !== "locked" && input.text.trim().length === 0 && pane.editingId.length === 0
                        implicitWidth: 36
                        implicitHeight: 36
                        readonly property real lockDistance: 70
                        property real lockProgress: 0
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: App.recState === "holding" ? Qt.rgba(1, 0.32, 0.32, 0.18) : recArea.containsMouse ? Qt.rgba(0.5, 0.5, 0.5, 0.14) : "transparent"
                            scale: App.recState === "holding" ? 1.35 : 1
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: (App.recording ? App.recKind === "video" : App.recordMode === "video") ? "📷" : "🎤"
                            font.pixelSize: 18
                            scale: recArea.pressed && !App.recording ? 0.85 : 1
                            Behavior on scale { NumberAnimation { duration: 90 } }
                        }
                        // замочек над кнопкой: тянется и светлеет, пока ведут вверх
                        Rectangle {
                            visible: App.recState === "holding"
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: -height - 18 - 10 * recButton.lockProgress
                            width: 38
                            height: 64
                            radius: 19
                            color: Ui.c.surface
                            border.color: Qt.rgba(0.5, 0.5, 0.5, 0.25)
                            scale: 1 + 0.18 * recButton.lockProgress
                            Column {
                                anchors.centerIn: parent
                                spacing: 6
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "⌃"; font.pixelSize: 16; color: recButton.lockProgress > 0.5 ? Ui.c.primary : Ui.c.textMuted }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "🔒"; font.pixelSize: 16; opacity: 0.5 + 0.5 * recButton.lockProgress }
                            }
                        }
                        MouseArea {
                            id: recArea
                            anchors.fill: parent
                            hoverEnabled: true
                            pressAndHoldInterval: 300
                            property real pressY: 0
                            onPressed: (mouse) => { pressY = mouse.y; recButton.lockProgress = 0 }
                            onClicked: App.toggleRecordMode()
                            onPressAndHold: { list.stickToEnd = true; App.beginRecording() }
                            onPositionChanged: (mouse) => {
                                if (App.recState !== "holding") return
                                recButton.lockProgress = Math.max(0, Math.min(1, (pressY - mouse.y) / recButton.lockDistance))
                                if (recButton.lockProgress >= 1) App.lockRecording()
                            }
                            onReleased: if (App.recState === "holding") App.finishRecording(true)
                            onCanceled: if (App.recState === "holding") App.finishRecording(false)
                        }
                        ToolTip.visible: recArea.containsMouse && !App.recording && !recArea.pressed
                        ToolTip.text: App.recordMode === "video" ? Ui.t("media_videoNote") : Ui.t("media_voiceNote")
                        ToolTip.delay: 800
                    }
                    IconButton {
                        visible: input.text.trim().length > 0 || pane.editingId.length > 0
                        glyph: "➤"
                        tint: Ui.c.primary
                        tip: Ui.t("common_send")
                        onClicked: pane.send()
                    }
                }
            }
        }
    }

    function send() {
        const text = input.text.trim()
        if (text.length === 0) return
        if (editingId.length > 0) App.editMessage(editingId, text)
        else App.sendText(text, replyToId)
        input.text = ""
        replyToId = ""
        editingId = ""
        list.stickToEnd = true
    }

    // перетаскивание файлов в окно
    DropArea {
        anchors.fill: parent
        onDropped: (drop) => { if (drop.hasUrls) { App.sendFiles(drop.urls, ""); list.stickToEnd = true } }
        Rectangle { anchors.fill: parent; visible: parent.containsDrag; color: Qt.rgba(Ui.c.primary.r, Ui.c.primary.g, Ui.c.primary.b, 0.18); border.color: Ui.c.primary; border.width: 2 }
    }

    FileDialog {
        id: fileDialog
        fileMode: FileDialog.OpenFiles
        onAccepted: { App.sendFiles(selectedFiles, ""); list.stickToEnd = true }
    }
    FileDialog {
        id: saveDialog
        property string messageId
        fileMode: FileDialog.SaveFile
        onAccepted: App.saveMedia(messageId, selectedFile)
    }
    FileDialog {
        id: wallpaperDialog
        nameFilters: ["Images (*.jpg *.jpeg *.png *.webp)"]
        onAccepted: wallpaperPreview.open(selectedFile)
    }

    StickerPanel { id: stickers; onEmojiPicked: (e) => input.insert(input.cursorPosition, e) }
    PeerProfile { id: peerProfile }
    TransfersSheet { id: transfers }

    // пак стикера из переписки: добавить в панель / убрать
    Sheet {
        id: packSheet
        property var pack: ({})
        property bool loading: false
        function show(stickerId) {
            pack = {}
            loading = true
            open()
            App.showStickerPack(stickerId)
        }
        title: loading ? Ui.t("sticker_preview") : (pack.title || Ui.t("sticker_loadFailed"))
        Connections {
            target: App
            function onStickerPackShown(p) { packSheet.pack = p; packSheet.loading = false }
        }
        BusyIndicator { visible: packSheet.loading; running: visible; anchors.horizontalCenter: parent.horizontalCenter }
        Text {
            visible: !packSheet.loading && packSheet.pack.deleted === true
            text: Ui.t("sticker_packDeleted")
            color: Ui.c.textMuted
        }
        Text {
            visible: !packSheet.loading && (packSheet.pack.stickers || []).length > 0
            text: Ui.t("sticker_count", [(packSheet.pack.stickers || []).length])
            color: Ui.c.textMuted
            font.pixelSize: 13
        }
        // нажатие — отправить стикер в этот чат (и закрыть окно), удержание — превью
        StickerGrid {
            id: packGrid
            visible: !packSheet.loading && count > 0
            width: parent.width
            height: Math.min(contentHeight, 320)
            model: packSheet.pack.stickers || []
            canSend: !pane.blocked
            onSendRequested: (s) => {
                packSheet.close()
                App.sendSticker(s.id, s.packId, s.format)
            }
        }
        SheetButtons {
            FlatButton {
                visible: !packSheet.loading && !!packSheet.pack.id && !packSheet.pack.deleted
                text: packSheet.pack.installed ? Ui.t("sticker_remove") : Ui.t("sticker_addPack")
                danger: !!packSheet.pack.installed
                enabled: !App.busy
                onClicked: {
                    if (packSheet.pack.installed) App.removeStickerPack(packSheet.pack.id)
                    else App.installStickerPack(packSheet.pack.id)
                    packSheet.close()
                }
            }
            FlatButton { text: Ui.t("sticker_ok"); primary: false; onClicked: packSheet.close() }
        }
    }

    WallpaperPreview { id: wallpaperPreview; anchors.fill: parent; z: 10 }

    // живое превью камеры, пока пишется кружок — квадрат со скруглением над полем ввода
    Item {
        id: notePreview
        z: 5
        readonly property bool active: App.recKind === "video"
        width: Math.min(320, pane.width - 48)
        height: width
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 96
        visible: opacity > 0
        opacity: active ? 1 : 0
        scale: active ? 1 : 0.85
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Rectangle { anchors.fill: parent; radius: 24; color: "black" }
        VideoView { anchors.fill: parent; local: true; radius: 24 }
    }

    Sheet {
        id: deleteMsg
        property var ids: []
        property bool mine
        title: Ui.t("deleteMessage_title")
        ThemedCheck { id: delBoth; text: Ui.t("deleteMessage_alsoForPeer") + " " + App.openChat; checked: true }
        SheetButtons {
            FlatButton { text: Ui.t("action_delete"); danger: true; onClicked: { App.deleteMessages(deleteMsg.ids, delBoth.checked); deleteMsg.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: deleteMsg.close() }
        }
    }

    Sheet {
        id: clearSheet
        title: Ui.t("chatMenu_clearHistoryTitle")
        ThemedCheck { id: clearBoth; text: Ui.t("deleteMessage_alsoForPeer") + " " + App.openChat; checked: true }
        SheetButtons {
            FlatButton { text: Ui.t("chatMenu_clearHistoryConfirm"); danger: true; onClicked: { App.clearHistory(clearBoth.checked); clearSheet.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: clearSheet.close() }
        }
    }

    Sheet {
        id: deleteSheet
        title: Ui.t("chatMenu_deleteChatTitle")
        ThemedCheck { id: deleteBoth; text: Ui.t("deleteMessage_alsoForPeer") + " " + App.openChat; checked: true }
        SheetButtons {
            FlatButton { text: Ui.t("chatMenu_deleteChatConfirm"); danger: true; onClicked: { App.deleteChat(App.openChat, deleteBoth.checked); deleteSheet.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: deleteSheet.close() }
        }
    }

    Sheet {
        id: resetSheet
        title: Ui.t("chat_resetSessionTitle")
        Text { text: Ui.t("chat_resetSessionBody"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width }
        SheetButtons {
            FlatButton { text: Ui.t("chat_resetSessionConfirm"); onClicked: { App.resetSession(); resetSheet.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: resetSheet.close() }
        }
    }

    Sheet {
        id: forward
        property string text
        title: Ui.t("forward_title")
        ListView {
            width: parent.width
            height: Math.min(contentHeight, 360)
            clip: true
            model: App.chats
            delegate: ItemDelegate {
                width: ListView.view.width
                contentItem: RowLayout {
                    spacing: 10
                    Avatar { size: 32; name: model.login; source: model.avatar }
                    Text { text: model.login; color: Ui.c.textPrimary; font.pixelSize: 15; Layout.fillWidth: true }
                }
                background: Rectangle { color: parent.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.12) : "transparent"; radius: 8 }
                onClicked: { App.forwardText(forward.text, model.login); forward.close() }
            }
        }
    }
}
