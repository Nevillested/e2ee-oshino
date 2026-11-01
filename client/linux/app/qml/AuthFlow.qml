import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Oshinobu.Core

// Вход, регистрация с TOTP и восстановление пароля / аутентификатора по коду из письма.
Item {
    id: root
    property string regLogin
    property string regPassword

    StackView {
        id: stack
        anchors.fill: parent
        initialItem: welcome
        pushEnter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 }
                NumberAnimation { property: "x"; from: 60; to: 0; duration: 260; easing.type: Easing.OutCubic }
            }
        }
        pushExit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 180 } }
        popEnter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 }
                NumberAnimation { property: "x"; from: -60; to: 0; duration: 260; easing.type: Easing.OutCubic }
            }
        }
        popExit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 180 } }
    }

    Connections {
        target: App
        function onTotpReady(url, secret) { stack.push(totpSetup, { otpUrl: url, secret: secret }) }
        function onTotpVerified() { root.regPassword = ""; stack.pop(null); stack.push(loginForm) }
    }

    component Card: Rectangle {
        default property alias body: col.data
        property string heading
        color: "transparent"
        ColumnLayout {
            id: col
            anchors.centerIn: parent
            width: Math.min(380, parent.width - 48)
            spacing: 14
            Text {
                text: heading
                visible: heading.length > 0
                color: Ui.c.textPrimary
                font.pixelSize: 24
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
                Layout.bottomMargin: 8
            }
        }
    }

    Component {
        id: welcome
        Card {
            Image {
                source: "qrc:/qt/qml/Oshinobu/icons/oshinobu.png"
                Layout.preferredWidth: 112
                Layout.preferredHeight: 112
                Layout.alignment: Qt.AlignHCenter
            }
            Text {
                text: "Oshinobu"
                color: Ui.c.textPrimary
                font.pixelSize: 30
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
            }
            Text {
                text: Ui.t("encryption_info")
                color: Ui.c.textMuted
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
                Layout.bottomMargin: 18
            }
            FlatButton { text: Ui.t("welcome_login"); Layout.fillWidth: true; onClicked: stack.push(loginForm) }
            FlatButton { text: Ui.t("welcome_register"); primary: false; outline: true; Layout.fillWidth: true; onClicked: stack.push(registerForm) }
            Row {
                Layout.alignment: Qt.AlignHCenter
                spacing: 6
                FlatButton { text: "RU"; primary: App.lang === "ru"; implicitHeight: 32; onClicked: App.setLanguage("ru") }
                FlatButton { text: "EN"; primary: App.lang === "en"; implicitHeight: 32; onClicked: App.setLanguage("en") }
            }
        }
    }

    Component {
        id: loginForm
        Card {
            heading: Ui.t("login_title")
            Field { id: login; placeholderText: Ui.t("auth_loginHint"); Layout.fillWidth: true; focus: true; onAccepted: password.forceActiveFocus() }
            Field { id: password; placeholderText: Ui.t("auth_passwordHint"); secret: true; Layout.fillWidth: true; onAccepted: totp.forceActiveFocus() }
            Field {
                id: totp
                placeholderText: Ui.t("auth_totpHint")
                Layout.fillWidth: true
                inputMethodHints: Qt.ImhDigitsOnly
                validator: RegularExpressionValidator { regularExpression: /[0-9]{0,6}/ }
                onAccepted: go.clicked()
            }
            FlatButton {
                id: go
                text: App.busy ? Ui.t("auth_loggingIn") : Ui.t("welcome_login")
                enabled: !App.busy && login.text.length > 0 && password.text.length > 0 && totp.text.length === 6
                Layout.fillWidth: true
                onClicked: App.login(login.text, password.text, totp.text)
            }
            FlatButton { text: Ui.t("recovery_forgotPassword"); primary: false; Layout.fillWidth: true; onClicked: stack.push(recovery, { mode: "password", login: login.text }) }
            FlatButton { text: Ui.t("recovery_forgotTotp"); primary: false; Layout.fillWidth: true; onClicked: stack.push(recovery, { mode: "totp", login: login.text }) }
            FlatButton { text: Ui.t("common_back"); primary: false; Layout.fillWidth: true; onClicked: stack.pop() }
        }
    }

    Component {
        id: registerForm
        Card {
            heading: Ui.t("register_title")
            Field { id: rlogin; placeholderText: Ui.t("auth_loginHint"); Layout.fillWidth: true; focus: true; validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9]{0,32}/ } }
            Field { id: rpassword; placeholderText: Ui.t("auth_passwordHint"); secret: true; Layout.fillWidth: true }
            Text {
                text: Ui.t("password_requirementsHint")
                color: Ui.c.textMuted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Field { id: invite; placeholderText: Ui.t("auth_inviteCodeHint"); Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly }
            FlatButton {
                text: App.busy ? Ui.t("auth_registering") : Ui.t("welcome_register")
                enabled: !App.busy && rlogin.text.length >= 3 && rpassword.text.length >= 6 && invite.text.length > 0
                Layout.fillWidth: true
                onClicked: {
                    root.regLogin = rlogin.text
                    root.regPassword = rpassword.text
                    App.registerAccount(rlogin.text, rpassword.text, invite.text)
                }
            }
            FlatButton { text: Ui.t("common_back"); primary: false; Layout.fillWidth: true; onClicked: stack.pop() }
        }
    }

    Component {
        id: totpSetup
        Card {
            property string otpUrl
            property string secret
            heading: Ui.t("totp_title")
            Text {
                text: Ui.t("totp_manualEntry")
                color: Ui.c.textMuted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: secretText.implicitHeight + 24
                radius: Ui.radius
                color: Ui.c.surface
                TextEdit {
                    id: secretText
                    anchors.centerIn: parent
                    width: parent.width - 24
                    text: secret.replace(/(.{4})/g, "$1 ").trim()
                    readOnly: true
                    selectByMouse: true
                    color: Ui.c.textPrimary
                    font.family: "monospace"
                    font.pixelSize: 17
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAnywhere
                }
            }
            FlatButton { text: Ui.t("action_copy"); primary: false; Layout.fillWidth: true; onClicked: { App.copyText(secret) } }
            Field {
                id: code
                placeholderText: Ui.t("auth_totpHint")
                Layout.fillWidth: true
                inputMethodHints: Qt.ImhDigitsOnly
                validator: RegularExpressionValidator { regularExpression: /[0-9]{0,6}/ }
                onAccepted: confirm.clicked()
            }
            FlatButton {
                id: confirm
                text: Ui.t("totp_confirm")
                enabled: !App.busy && code.text.length === 6
                Layout.fillWidth: true
                onClicked: App.confirmTotp(root.regLogin, root.regPassword, code.text)
            }
        }
    }

    Component {
        id: recovery
        Card {
            id: rec
            property string mode
            property string login
            property bool codeSent: false
            heading: mode === "totp" ? Ui.t("recovery_titleTotp") : Ui.t("recovery_title")
            Connections {
                target: App
                function onRecoveryCodeSent() { rec.codeSent = true }
                function onRecoveryDone(url) {
                    if (rec.mode === "password") { App.info(Ui.t("recovery_success")); stack.pop(null) }
                }
            }
            Field { id: rlog; text: rec.login; placeholderText: Ui.t("auth_loginHint"); Layout.fillWidth: true; enabled: !rec.codeSent }
            Text {
                text: rec.codeSent ? Ui.t("recovery_requestSentInfo") : ""
                visible: rec.codeSent
                color: Ui.c.textMuted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            FlatButton { text: Ui.t("recovery_sendCode"); visible: !rec.codeSent; enabled: !App.busy && rlog.text.length > 0; Layout.fillWidth: true; onClicked: App.requestRecovery(rlog.text) }
            Field { id: rcode; visible: rec.codeSent; placeholderText: Ui.t("recovery_codeHint"); Layout.fillWidth: true }
            Field { id: newPass; visible: rec.codeSent && rec.mode === "password"; placeholderText: Ui.t("recovery_newPasswordHint"); secret: true; Layout.fillWidth: true }
            FlatButton {
                visible: rec.codeSent
                text: Ui.t("recovery_save")
                enabled: !App.busy && rcode.text.length > 0 && (rec.mode === "totp" || newPass.text.length >= 6)
                Layout.fillWidth: true
                onClicked: {
                    if (rec.mode === "password") App.resetPassword(rlog.text, rcode.text, newPass.text)
                    else { root.regLogin = rlog.text; root.regPassword = ""; App.resetTotp(rlog.text, rcode.text) }
                }
            }
            FlatButton { text: Ui.t("common_back"); primary: false; Layout.fillWidth: true; onClicked: stack.pop() }
        }
    }
}
