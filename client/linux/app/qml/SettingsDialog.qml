import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Oshinobu.Core

// Боковое меню как на Android: шапка профиля по центру и компактный список пунктов;
// каждый пункт открывает своё окно настроек.
Drawer {
    id: drawer
    width: 320
    height: parent.height
    edge: Qt.LeftEdge
    background: Rectangle { color: Ui.c.background }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }

    readonly property var timeouts: [60, 300, 900, 3600]
    function privacyText(v) { return v === 1 ? Ui.t("privacy_everyone") : v === 2 ? Ui.t("privacy_contactsOnly") : Ui.t("privacy_nobody") }

    Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        Column {
            id: column
            width: drawer.width

            // шапка профиля — по центру; «назад» слева закрывает меню
            Item {
                width: parent.width
                height: 196
                IconButton {
                    x: 10
                    y: 10
                    glyph: "←"
                    tip: Ui.t("common_back")
                    onClicked: drawer.close()
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    Avatar {
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: 84
                        name: App.myLogin
                        source: Ui.avatar(App.myAccountId)
                        scale: avatarHover.hovered ? 1.04 : 1
                        Behavior on scale { NumberAnimation { duration: 140 } }
                        HoverHandler { id: avatarHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: avatarMenu.popup() }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: App.myAccount.displayName || App.myLogin
                        color: Ui.c.textPrimary
                        font.pixelSize: 18
                        font.bold: true
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "@" + App.myLogin
                        color: Ui.c.textMuted
                        font.pixelSize: 13
                    }
                }
            }
            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0.5, 0.5, 0.5, 0.15) }

            SettingsItem { glyph: "👤"; tint: "#2AABEE"; label: Ui.t("profile_title"); onClicked: profileSheet.open() }
            SettingsItem { glyph: "✉"; tint: "#5AC8FA"; label: Ui.t("settings_email"); value: App.myAccount.email || ""; onClicked: emailSheet.open() }
            SettingsItem { glyph: "🔑"; tint: "#FF9F0A"; label: Ui.t("settings_changePassword"); onClicked: passwordSheet.open() }
            SettingsItem {
                glyph: "🌐"; tint: "#32C769"; label: Ui.t("settings_language"); value: App.lang === "ru" ? Ui.t("language_russian") : Ui.t("language_english")
                onClicked: choice.ask(Ui.t("language_title"), [{ text: Ui.t("language_russian"), value: "ru" }, { text: Ui.t("language_english"), value: "en" }], App.lang, v => App.setLanguage(v))
            }
            SettingsItem { glyph: "🎨"; tint: "#AF52DE"; label: Ui.t("settings_theme"); value: Ui.t(App.theme.title); onClicked: themeSheet.open() }
            SettingsItem { glyph: "🛡"; tint: "#34C759"; label: Ui.t("settings_privacy"); onClicked: privacySheet.open() }
            SettingsItem { glyph: "🔒"; tint: "#5E5CE6"; label: Ui.t("settings_appLock"); value: App.appLock.enabled ? Ui.t("applock_on") : Ui.t("applock_off"); onClicked: lockSheet.open() }
            SettingsItem { glyph: "⇅"; tint: "#0A84FF"; label: Ui.t("transfers_title"); value: App.transfers.length > 0 ? String(App.transfers.length) : ""; onClicked: transfersSheet.open() }
            SettingsItem { glyph: "🧹"; tint: "#00C7BE"; label: Ui.t("settings_clearCache"); onClicked: cacheSheet.open() }
            SettingsItem { glyph: "ℹ"; tint: "#8E8E93"; label: Ui.t("settings_about"); onClicked: aboutSheet.open() }
            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0.5, 0.5, 0.5, 0.15) }
            SettingsItem { glyph: "🚪"; tint: "#636366"; label: Ui.t("linux_quit"); onClicked: App.quit() }
            SettingsItem { glyph: "⇥"; tint: "#FF3B30"; label: Ui.t("settings_logout"); danger: true; onClicked: logoutSheet.open() }
            SettingsItem { glyph: "🗑"; tint: "#B00020"; label: Ui.t("settings_deleteAccount"); danger: true; onClicked: deleteSheet.open() }
            Item { width: 1; height: 16 }
        }
    }

    AppMenu {
        id: avatarMenu
        AppMenuItem { text: Ui.t("settings_avatarChange"); onTriggered: avatarDialog.open() }
        AppMenuItem { text: Ui.t("settings_avatarRemove"); danger: true; onTriggered: App.removeAvatar() }
    }
    FileDialog { id: avatarDialog; nameFilters: ["Images (*.jpg *.jpeg *.png *.webp)"]; onAccepted: App.setAvatar(selectedFile) }

    ChoiceSheet { id: choice }

    // ---------------- профиль ----------------
    Sheet {
        id: profileSheet
        title: Ui.t("profile_title")
        Avatar {
            anchors.horizontalCenter: parent.horizontalCenter
            size: 96
            name: App.myLogin
            source: Ui.avatar(App.myAccountId)
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: avatarMenu.popup() }
        }
        Text { text: Ui.t("profile_displayName"); color: Ui.c.textMuted; font.pixelSize: 13 }
        Field { id: nameField; width: parent.width; text: App.myAccount.displayName || ""; placeholderText: Ui.t("profile_displayNameHint") }
        Text { text: Ui.t("profile_status"); color: Ui.c.textMuted; font.pixelSize: 13 }
        Field { id: statusField; width: parent.width; text: App.myAccount.status || ""; placeholderText: Ui.t("profile_statusHint") }
        Text { text: Ui.t("profile_birthday") + " (ГГГГ-ММ-ДД)"; color: Ui.c.textMuted; font.pixelSize: 13 }
        Field {
            id: birthdayField
            width: parent.width
            text: App.myAccount.birthday || ""
            placeholderText: "1990-01-31"
            validator: RegularExpressionValidator { regularExpression: /(\d{0,4})(-\d{0,2}){0,2}/ }
        }
        SheetButtons {
            FlatButton {
                text: Ui.t("common_save")
                enabled: !App.busy
                onClicked: {
                    if (nameField.text !== (App.myAccount.displayName || "")) App.updateDisplayName(nameField.text)
                    if (statusField.text !== (App.myAccount.status || "")) App.updateStatus(statusField.text)
                    if (birthdayField.text !== (App.myAccount.birthday || "")) App.updateBirthday(birthdayField.text)
                    profileSheet.close()
                }
            }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: profileSheet.close() }
        }
    }

    // ---------------- тема ----------------
    Sheet {
        id: themeSheet
        title: Ui.t("settings_theme")
        Grid {
            columns: 3
            spacing: 12
            anchors.horizontalCenter: parent.horizontalCenter
            Repeater {
                model: App.themeIds()
                delegate: Column {
                    spacing: 6
                    readonly property var tc: App.themeColors(modelData)
                    Rectangle {
                        width: 110
                        height: 86
                        radius: 14
                        color: tc.background
                        border.width: App.themeId === modelData ? 3 : 1
                        border.color: App.themeId === modelData ? tc.primary : Qt.rgba(0.5, 0.5, 0.5, 0.35)
                        Behavior on border.width { NumberAnimation { duration: 140 } }
                        scale: themeHover.hovered ? 1.04 : 1
                        Behavior on scale { NumberAnimation { duration: 140 } }
                        Rectangle { x: 10; y: 14; width: 60; height: 16; radius: 8; color: tc.surface }
                        Rectangle { x: 40; y: 38; width: 60; height: 16; radius: 8; color: tc.bubbleMine }
                        Rectangle { x: 10; y: 62; width: 44; height: 12; radius: 6; color: tc.surface }
                        HoverHandler { id: themeHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: App.setTheme(modelData) }
                    }
                    Text { text: Ui.t(tc.title); color: Ui.c.textPrimary; font.pixelSize: 13; anchors.horizontalCenter: parent.horizontalCenter }
                }
            }
        }
    }

    // ---------------- приватность ----------------
    Sheet {
        id: privacySheet
        title: Ui.t("privacy_title")
        Repeater {
            model: [
                { key: "privacy_findByLogin", field: "findByLogin", contacts: false },
                { key: "privacy_avatar", field: "avatarVisibility", contacts: true },
                { key: "privacy_birthday", field: "birthdayVisibility", contacts: true },
                { key: "privacy_status", field: "statusVisibility", contacts: true }
            ]
            delegate: ItemDelegate {
                width: parent ? parent.width : 0
                height: 58
                readonly property int current: App.myAccount[modelData.field] || 1
                background: Rectangle { radius: 10; color: parent.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.1) : "transparent" }
                contentItem: Column {
                    spacing: 2
                    Text { text: Ui.t(modelData.key); color: Ui.c.textPrimary; font.pixelSize: 15; width: parent.width; elide: Text.ElideRight }
                    Text { text: drawer.privacyText(current); color: Ui.c.primary; font.pixelSize: 13 }
                }
                onClicked: {
                    const opts = [{ text: Ui.t("privacy_everyone"), value: 1 }]
                    if (modelData.contacts) opts.push({ text: Ui.t("privacy_contactsOnly"), value: 2 })
                    opts.push({ text: Ui.t("privacy_nobody"), value: 3 })
                    const field = modelData.field
                    choice.ask(Ui.t(modelData.key), opts, current, v => {
                        const a = App.myAccount
                        const p = { findByLogin: a.findByLogin || 1, avatarVisibility: a.avatarVisibility || 1, birthdayVisibility: a.birthdayVisibility || 1, statusVisibility: a.statusVisibility || 1 }
                        p[field] = v
                        App.updatePrivacy(p.findByLogin, p.avatarVisibility, p.birthdayVisibility, p.statusVisibility)
                    })
                }
            }
        }
    }

    // ---------------- блокировка ----------------
    Sheet {
        id: lockSheet
        title: Ui.t("applock_title")
        SettingsItem { glyph: "🔢"; tint: "#5E5CE6"; label: App.appLock.hasPin ? Ui.t("applock_changePin") : Ui.t("applock_setPin"); onClicked: pinSheet.open() }
        SettingsItem {
            visible: App.appLock.hasPin
            glyph: "⏱"; tint: "#FF9F0A"; label: Ui.t("applock_timeout"); value: Ui.t("applock_timeout_" + App.appLock.timeout)
            onClicked: choice.ask(Ui.t("applock_timeout"), drawer.timeouts.map(s => ({ text: Ui.t("applock_timeout_" + s), value: s })), App.appLock.timeout, v => App.setLockTimeout(v))
        }
        SettingsItem { visible: App.appLock.hasPin; glyph: "✕"; tint: "#FF3B30"; label: Ui.t("applock_removePin"); danger: true; onClicked: App.removePin() }
    }

    Sheet {
        id: pinSheet
        title: Ui.t("applock_newPin")
        Field { id: pin1; width: parent.width; secret: true; placeholderText: Ui.t("applock_newPin"); validator: RegularExpressionValidator { regularExpression: /[0-9]{0,8}/ } }
        Field { id: pin2; width: parent.width; secret: true; placeholderText: Ui.t("applock_confirmPin"); validator: RegularExpressionValidator { regularExpression: /[0-9]{0,8}/ } }
        Text { visible: pin2.text.length > 0 && pin1.text !== pin2.text; text: Ui.t("applock_pinMismatch"); color: "#E5534B" }
        SheetButtons {
            FlatButton {
                text: Ui.t("common_save")
                enabled: pin1.text.length >= 4 && pin1.text === pin2.text
                onClicked: { App.setPin(pin1.text); pin1.text = ""; pin2.text = ""; pinSheet.close(); App.info(Ui.t("applock_pinSet")) }
            }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: pinSheet.close() }
        }
    }

    // ---------------- почта и пароль ----------------
    Sheet {
        id: emailSheet
        property bool sent: false
        title: Ui.t("email_title")
        Connections { target: App; function onEmailCodeSent() { emailSheet.sent = true } }
        Text { text: Ui.t("email_description"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width }
        Field { id: emailField; width: parent.width; placeholderText: Ui.t("email_hint"); enabled: !emailSheet.sent }
        Field { id: emailCode; width: parent.width; visible: emailSheet.sent; placeholderText: Ui.t("recovery_codeHint") }
        SheetButtons {
            FlatButton {
                text: emailSheet.sent ? Ui.t("recovery_confirmCode") : Ui.t("email_sendCode")
                enabled: !App.busy && (emailSheet.sent ? emailCode.text.length > 0 : emailField.text.indexOf("@") > 0)
                onClicked: {
                    if (emailSheet.sent) { App.confirmEmailCode(emailCode.text); emailSheet.sent = false; emailSheet.close() }
                    else App.requestEmailCode(emailField.text)
                }
            }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: { emailSheet.sent = false; emailSheet.close() } }
        }
    }

    Sheet {
        id: passwordSheet
        title: Ui.t("changePassword_title")
        Field { id: newPass; width: parent.width; secret: true; placeholderText: Ui.t("recovery_newPasswordHint") }
        Field { id: newPass2; width: parent.width; secret: true; placeholderText: Ui.t("recovery_confirmPasswordHint") }
        Text { text: Ui.t("password_requirementsHint"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width; font.pixelSize: 12 }
        SheetButtons {
            FlatButton { text: Ui.t("common_save"); enabled: newPass.text.length >= 6 && newPass.text === newPass2.text; onClicked: { App.changePassword(newPass.text); passwordSheet.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: passwordSheet.close() }
        }
    }

    // ---------------- передачи, кэш, о приложении ----------------
    TransfersSheet { id: transfersSheet }

    Sheet {
        id: cacheSheet
        title: Ui.t("settings_clearCacheTitle")
        SheetButtons {
            FlatButton { text: Ui.t("settings_clearCache"); onClicked: { App.clearCache(); cacheSheet.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: cacheSheet.close() }
        }
    }

    Sheet {
        id: aboutSheet
        title: Ui.t("about_title")
        Image { anchors.horizontalCenter: parent.horizontalCenter; source: "qrc:/qt/qml/Oshinobu/icons/oshinobu.png"; width: 72; height: 72 }
        Text { text: "Oshinobu " + Qt.application.version; color: Ui.c.textPrimary; font.pixelSize: 16; anchors.horizontalCenter: parent.horizontalCenter }
        Text { text: Ui.t("encryption_info"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width; horizontalAlignment: Text.AlignHCenter }
        SettingsItem { glyph: "📄"; tint: "#8E8E93"; label: Ui.t("about_terms"); onClicked: Qt.openUrlExternally("https://ee2e.oshino.space/terms/" + App.lang + "/") }
        SettingsItem { glyph: "🛡"; tint: "#8E8E93"; label: Ui.t("about_privacy"); onClicked: Qt.openUrlExternally("https://ee2e.oshino.space/privacy/" + App.lang + "/") }
    }

    // ---------------- выход и удаление ----------------
    Sheet {
        id: logoutSheet
        title: Ui.t("account_logoutTitle")
        Text { text: Ui.t("account_logoutBody"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width }
        SheetButtons {
            FlatButton { text: Ui.t("account_logoutConfirm"); danger: true; onClicked: { logoutSheet.close(); drawer.close(); App.logout() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: logoutSheet.close() }
        }
    }

    Sheet {
        id: deleteSheet
        title: Ui.t("account_deleteTitle")
        Text { text: Ui.t("account_deleteBody"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width }
        SheetButtons {
            FlatButton { text: Ui.t("account_deleteConfirm"); danger: true; onClicked: { deleteSheet.close(); drawer.close(); App.deleteAccount() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: deleteSheet.close() }
        }
    }
}
