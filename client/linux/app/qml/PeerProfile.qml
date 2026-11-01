import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Oshinobu.Core

// Профиль собеседника как на Android: только профиль — фото, имя, «в сети», логин, статус,
// дата рождения (звонок, уведомления и блокировка — в шапке чата и её меню).
Sheet {
    id: sheet
    property string login
    property var profile: ({})
    readonly property var info: App.openChatInfo
    preferredWidth: 400
    onOpened: { profile = App.profileOf(login); App.loadProfile(login) }
    Connections {
        target: App
        function onProfileLoaded(l) { if (l === sheet.login) sheet.profile = App.profileOf(l) }
    }

    Avatar {
        anchors.horizontalCenter: parent.horizontalCenter
        size: 112
        name: sheet.login
        source: Ui.avatar(sheet.info.accountId)
    }
    // имя и «был(а) в сети» — строго друг под другом, по центру
    Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: sheet.profile.displayName || sheet.login
        color: Ui.c.textPrimary
        font.pixelSize: 21
        font.bold: true
        elide: Text.ElideRight
    }
    FadeText {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: App.presence
        color: App.presence === Ui.t("presence_online") ? Ui.c.primary : Ui.c.textMuted
        pixelSize: 13
    }

    Rectangle {
        width: parent.width
        implicitHeight: details.implicitHeight + 16
        radius: 12
        color: Ui.c.surface
        Column {
            id: details
            x: 14
            y: 8
            width: parent.width - 28
            spacing: 10
            Column {
                width: parent.width
                Text { text: "@" + sheet.login; color: Ui.c.textPrimary; font.pixelSize: 15 }
                Text { text: Ui.t("profile_login"); color: Ui.c.textMuted; font.pixelSize: 12 }
            }
            Column {
                width: parent.width
                visible: (sheet.profile.status || "").length > 0
                Text { text: sheet.profile.status || ""; color: Ui.c.textPrimary; font.pixelSize: 15; wrapMode: Text.Wrap; width: parent.width }
                Text { text: Ui.t("profile_status"); color: Ui.c.textMuted; font.pixelSize: 12 }
            }
            Column {
                width: parent.width
                visible: (sheet.profile.birthday || "").length > 0
                Text { text: sheet.profile.birthday || ""; color: Ui.c.textPrimary; font.pixelSize: 15 }
                Text { text: Ui.t("profile_birthday"); color: Ui.c.textMuted; font.pixelSize: 12 }
            }
        }
    }
}
