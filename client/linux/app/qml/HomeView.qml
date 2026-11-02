import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Oshinobu.Core

// Главный экран как в Telegram Desktop: слева список чатов, справа переписка.
Item {
    id: home

    SplitView {
        anchors.fill: parent
        handle: Rectangle { implicitWidth: 1; color: Qt.rgba(0.5, 0.5, 0.5, 0.2) }

        // ---------------- список чатов ----------------
        Rectangle {
            id: chatListPane
            SplitView.preferredWidth: 340
            SplitView.minimumWidth: 260
            SplitView.maximumWidth: 520
            color: Ui.c.background

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 10
                    spacing: 8
                    IconButton { glyph: "☰"; tip: Ui.t("settings_title"); onClicked: settings.open() }
                    Field {
                        id: search
                        Layout.fillWidth: true
                        placeholderText: Ui.t("newChat_loginHint")
                        validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9]{0,32}/ }
                        onTextChanged: {
                            App.chats.filter = text
                            results.state = text.length > 0 ? "searching" : ""
                            lookupDelay.restart()
                        }
                        onAccepted: if (results.state === "found") results.openFound()
                        Keys.onEscapePressed: search.clear()
                        rightPadding: text.length > 0 ? 40 : 14
                        // крестик: очистить поле и снять с него фокус
                        function clear() {
                            text = ""
                            focus = false
                            home.forceActiveFocus()
                        }
                        IconButton {
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            size: 28
                            glyph: "✕"
                            visible: opacity > 0
                            opacity: search.text.length > 0 ? 1 : 0
                            scale: search.text.length > 0 ? 1 : 0.6
                            Behavior on opacity { NumberAnimation { duration: 140 } }
                            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            onClicked: search.clear()
                        }
                        Timer {
                            id: lookupDelay
                            interval: 450
                            onTriggered: if (search.text.length > 0) App.lookupLogin(search.text)
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.bottomMargin: 6
                    visible: App.connection !== "connected"
                    text: App.connection === "waitingForNetwork" ? Ui.t("connection_waitingForNetwork")
                        : App.connection === "reconnecting" ? Ui.t("connection_reconnecting") : Ui.t("connection_connecting")
                    color: Ui.c.textMuted
                    font.pixelSize: 13
                }

                // выпадающий результат поиска пользователя на сервере
                Rectangle {
                    id: results
                    property string foundLogin
                    property string foundAccount
                    state: ""
                    function openFound() { App.findAndOpen(foundLogin); search.text = "" }
                    Layout.fillWidth: true
                    Layout.leftMargin: 10
                    Layout.rightMargin: 10
                    Layout.preferredHeight: state === "" ? 0 : 56
                    Behavior on Layout.preferredHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    clip: true
                    radius: 12
                    color: Ui.c.surface
                    opacity: state === "" ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    Connections {
                        target: App
                        function onSearchResult(query, found, login, accountId) {
                            if (query.toLowerCase() !== search.text.toLowerCase()) return
                            results.foundLogin = login
                            results.foundAccount = accountId
                            results.state = found ? "found" : "notFound"
                        }
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10
                        BusyIndicator { visible: results.state === "searching"; running: visible; implicitWidth: 28; implicitHeight: 28 }
                        Avatar { visible: results.state === "found"; size: 36; name: results.foundLogin; source: Ui.avatar(results.foundAccount) }
                        Text {
                            Layout.fillWidth: true
                            text: results.state === "found" ? results.foundLogin : results.state === "notFound" ? Ui.t("error_userNotFound") : ""
                            color: results.state === "found" ? Ui.c.textPrimary : Ui.c.textMuted
                            font.pixelSize: 15
                            font.bold: results.state === "found"
                            elide: Text.ElideRight
                        }
                    }
                    HoverHandler { cursorShape: results.state === "found" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                    TapHandler { enabled: results.state === "found"; onTapped: results.openFound() }
                }

                ListView {
                    id: list
                    add: Transition { NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: 200 } NumberAnimation { property: "x"; from: -20; to: 0; duration: 220; easing.type: Easing.OutCubic } }
                    remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 180 } }
                    displaced: Transition { NumberAnimation { properties: "y"; duration: 220; easing.type: Easing.OutCubic } }
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: App.chats
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        id: row
                        width: ListView.view.width
                        height: 68
                        highlighted: App.openChat === model.login
                        onClicked: App.openChatWith(model.login)
                        background: Item {
                            Rectangle {
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                anchors.topMargin: 2
                                anchors.bottomMargin: 2
                                radius: 12
                                color: row.highlighted ? Qt.rgba(Ui.c.primary.r, Ui.c.primary.g, Ui.c.primary.b, 0.22)
                                     : row.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.1) : "transparent"
                                Behavior on color { ColorAnimation { duration: 140 } }
                            }
                        }
                        contentItem: RowLayout {
                            spacing: 12
                            Avatar { size: 48; name: model.login; source: model.avatar }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: (model.pinned ? "📌 " : "") + model.login + (model.muted ? " 🔕" : "")
                                        color: Ui.c.textPrimary
                                        font.pixelSize: 15
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Ticks {
                                        visible: model.isMine
                                        read: model.isRead
                                        color: model.isRead ? Ui.c.primary : Ui.c.textMuted
                                        pixelSize: 12
                                    }
                                    Text {
                                        text: model.time
                                        color: model.isMine && model.isRead ? Ui.c.primary : Ui.c.textMuted
                                        font.pixelSize: 12
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: model.deleted ? Ui.t("home_deletedAccount") : model.preview
                                        color: Ui.c.textMuted
                                        font.pixelSize: 14
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                    Rectangle {
                                        visible: model.unread > 0
                                        radius: height / 2
                                        color: model.muted ? Ui.c.textMuted : Ui.c.primary
                                        implicitHeight: 20
                                        implicitWidth: Math.max(20, badge.implicitWidth + 12)
                                        Text { id: badge; anchors.centerIn: parent; text: model.unread; color: Ui.c.onPrimary; font.pixelSize: 12; font.bold: true }
                                    }
                                }
                            }
                        }
                        // правый клик — MouseArea поверх: TapHandler внутри ItemDelegate (Qt 6.2) не забирает
                        // нажатие, и делегат открывал чат вместо меню
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.RightButton
                            onClicked: { chatMenu.login = model.login; chatMenu.muted = model.muted; chatMenu.pinned = model.pinned; chatMenu.blocked = model.blockedByMe; chatMenu.popup() }
                        }
                    }
                }
            }
        }

        // ---------------- переписка ----------------
        Rectangle {
            SplitView.fillWidth: true
            color: Ui.c.chatBackground
            Loader {
                anchors.fill: parent
                active: App.openChat.length > 0
                sourceComponent: ChatPane {}
            }
            Text {
                anchors.centerIn: parent
                visible: App.openChat.length === 0
                text: Ui.t("newChat_title")
                color: Ui.c.textMuted
                font.pixelSize: 15
                padding: 10
                Rectangle { anchors.fill: parent; z: -1; radius: 14; color: Qt.rgba(0, 0, 0, 0.18) }
            }
        }
    }

    AppMenu {
        id: chatMenu
        property string login
        property bool muted
        property bool pinned
        property bool blocked
        // как на Android: закреп, звук, блокировка, очистить историю, удалить чат
        AppMenuItem { text: chatMenu.pinned ? Ui.t("chatMenu_unpin") : Ui.t("chatMenu_pin"); onTriggered: App.setChatPinned(chatMenu.login, !chatMenu.pinned) }
        AppMenuItem { text: chatMenu.muted ? Ui.t("chatMenu_unmute") : Ui.t("chatMenu_mute"); onTriggered: App.setMuted(chatMenu.login, !chatMenu.muted) }
        AppMenuItem { text: chatMenu.blocked ? Ui.t("chatMenu_unblock") : Ui.t("chatMenu_block"); onTriggered: App.setBlocked(chatMenu.login, !chatMenu.blocked) }
        AppMenuSeparator {}
        AppMenuItem { text: Ui.t("chatMenu_clearHistory"); danger: true; onTriggered: { clearChat.login = chatMenu.login; clearChat.open() } }
        AppMenuItem { text: Ui.t("chatMenu_deleteChat"); danger: true; onTriggered: { deleteChat.login = chatMenu.login; deleteChat.open() } }
    }

    Sheet {
        id: clearChat
        property string login
        title: Ui.t("chatMenu_clearHistoryTitle")
        ThemedCheck { id: clearForBoth; text: Ui.t("deleteMessage_alsoForPeer") + " " + clearChat.login; checked: true }
        SheetButtons {
            FlatButton { text: Ui.t("chatMenu_clearHistoryConfirm"); danger: true; onClicked: { App.clearHistory(clearChat.login, clearForBoth.checked); clearChat.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: clearChat.close() }
        }
    }

    Sheet {
        id: deleteChat
        property string login
        title: Ui.t("chatMenu_deleteChatTitle")
        ThemedCheck { id: forBoth; text: Ui.t("deleteMessage_alsoForPeer") + " " + deleteChat.login; checked: true }
        SheetButtons {
            FlatButton { text: Ui.t("chatMenu_deleteChatConfirm"); danger: true; onClicked: { App.deleteChat(deleteChat.login, forBoth.checked); deleteChat.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: deleteChat.close() }
        }
    }

    // боковое меню — ровно по ширине списка чатов
    SettingsDialog { id: settings; width: chatListPane.width }
}
