import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Oshinobu.Core

// Панель эмодзи и стикеров (как на Android): внизу переключатель «Эмодзи | Стикеры», страницы
// выезжают вбок. Стикеры: «Недавние» и паки; свайп по сетке — соседний пак, нажатие на пак —
// открывается сразу, коротко проявляясь. Правый клик по паку — убрать.
Popup {
    id: panel
    parent: Overlay.overlay
    x: parent.width - width - 16
    y: parent.height - height - 80
    width: 380
    height: 440
    property int page: 0 // 0 — эмодзи, 1 — стикеры
    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160; easing.type: Easing.OutCubic }
            NumberAnimation { property: "y"; from: panel.parent.height - panel.height - 60; to: panel.parent.height - panel.height - 80; duration: 180; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 120 } }
    padding: 0
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle { radius: 16; color: Ui.c.surface; border.color: Qt.rgba(0.5, 0.5, 0.5, 0.25) }

    // «Недавние» — своя модель у первой страницы: их смена не пересоздаёт страницы паков
    readonly property var pages: [{ id: "recent" }].concat(App.stickerPacks)

    signal emojiPicked(string emoji)

    function openPage(index) {
        if (index === view.currentIndex) return
        appear.stop()
        view.opacity = 0
        view.scale = 0.97
        view.setCurrentIndex(index)
        appear.start()
    }
    ParallelAnimation {
        id: appear
        NumberAnimation { target: view; property: "opacity"; to: 1; duration: 160; easing.type: Easing.OutCubic }
        NumberAnimation { target: view; property: "scale"; to: 1; duration: 160; easing.type: Easing.OutCubic }
    }

    contentItem: Item {
        clip: true

    // ---------------- эмодзи ----------------
    Flickable {
        id: emojiPage
        width: parent.width
        height: parent.height - 48
        x: (0 - panel.page) * width
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        contentHeight: emojiColumn.implicitHeight + 12
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        Column {
            id: emojiColumn
            x: 8
            y: 6
            width: parent.width - 16
            spacing: 6
            Repeater {
                model: App.emojiCategories
                delegate: Column {
                    width: emojiColumn.width
                    spacing: 2
                    Text { text: Ui.t(modelData.title); color: Ui.c.textMuted; font.pixelSize: 12; font.bold: true; leftPadding: 4 }
                    Grid {
                        columns: 8
                        Repeater {
                            model: modelData.emojis
                            delegate: AbstractButton {
                                width: emojiColumn.width / 8
                                height: width
                                hoverEnabled: true
                                contentItem: Text { text: modelData; font.pixelSize: 24; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                background: Rectangle { radius: 10; color: parent.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.18) : "transparent"; Behavior on color { ColorAnimation { duration: 90 } } }
                                scale: down ? 0.85 : 1
                                Behavior on scale { NumberAnimation { duration: 90 } }
                                onClicked: panel.emojiPicked(modelData)
                            }
                        }
                    }
                }
            }
        }
    }

    ColumnLayout {
        id: stickersPage
        width: parent.width
        height: parent.height - 48
        x: (1 - panel.page) * width
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        spacing: 0
        ListView {
            id: tabs
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            Layout.margins: 6
            orientation: ListView.Horizontal
            spacing: 4
            clip: true
            model: panel.pages.length + 1
            currentIndex: view.currentIndex
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: AbstractButton {
                width: 44
                height: 44
                readonly property bool isAdd: index === panel.pages.length
                readonly property var page: isAdd ? null : panel.pages[index]
                background: Rectangle { radius: 12; color: !isAdd && index === view.currentIndex ? Qt.rgba(Ui.c.primary.r, Ui.c.primary.g, Ui.c.primary.b, 0.2) : parent.hovered ? Qt.rgba(0.5, 0.5, 0.5, 0.12) : "transparent" }
                contentItem: Item {
                    Text {
                        anchors.centerIn: parent
                        visible: isAdd || index === 0
                        text: isAdd ? "+" : "🕓"
                        color: isAdd ? Ui.c.primary : Ui.c.textMuted
                        font.pixelSize: 20
                    }
                    StickerThumb {
                        anchors.fill: parent
                        anchors.margins: 5
                        visible: !isAdd && index > 0
                        stickerId: !isAdd && index > 0 && page.stickers && page.stickers.length > 0 ? page.stickers[0].id : ""
                    }
                }
                ToolTip.visible: hovered && !isAdd && index > 0
                ToolTip.text: page ? page.title || "" : ""
                onClicked: isAdd ? upload.open() : panel.openPage(index)
                MouseArea { // не TapHandler: внутри кнопки он не забирает правый клик (см. HomeView)
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    enabled: !isAdd && index > 0
                    onClicked: { removeSheet.packId = page.id; removeSheet.title = page.title; removeSheet.open() }
                }
            }
        }
        SwipeView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            Repeater {
                model: panel.pages
                delegate: StickerGrid {
                    leftMargin: 4
                    model: index === 0 ? App.recentStickers : modelData.stickers
                    // сначала закрыть: отправка меняет «Недавние», и обработчик мог не дожить до close()
                    onSendRequested: (s) => {
                        panel.close()
                        App.sendSticker(s.id, s.packId, s.format)
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: index === 0 && count === 0
                        text: Ui.t("sticker_recentEmpty")
                        color: Ui.c.textMuted
                        wrapMode: Text.Wrap
                        width: parent.width - 40
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }

    // переключатель «Эмодзи | Стикеры» — бегунок едет под выбранным
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        anchors.horizontalCenter: parent.horizontalCenter
        width: 220
        height: 34
        radius: 17
        color: Qt.rgba(0.5, 0.5, 0.5, 0.15)
        Rectangle {
            width: parent.width / 2 - 4
            height: parent.height - 6
            y: 3
            radius: height / 2
            x: 3 + panel.page * (parent.width / 2 - 2)
            color: Ui.c.primary
            Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        }
        Row {
            anchors.fill: parent
            Repeater {
                model: [Ui.t("sticker_tabEmoji"), Ui.t("sticker_tabStickers")]
                delegate: AbstractButton {
                    width: 110
                    height: 34
                    contentItem: Text {
                        text: modelData
                        color: panel.page === index ? Ui.c.onPrimary : Ui.c.textMuted
                        font.pixelSize: 13
                        font.bold: panel.page === index
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        Behavior on color { ColorAnimation { duration: 180 } }
                    }
                    background: null
                    onClicked: panel.page = index
                }
            }
        }
    }
    }

    // превью стикера: файл берётся из кэша пака (ядро скачает пак при первом показе)
    component StickerThumb: Item {
        property string stickerId
        StickerView {
            anchors.fill: parent
            anchors.margins: 4
            source: parent.stickerId.length ? App.stickerUrl(parent.stickerId, App.stickerRevision) : ""
        }
    }

    Sheet {
        id: removeSheet
        property string packId
        title: Ui.t("sticker_removeFromPanelTitle")
        Text { text: Ui.t("sticker_removeFromPanelBody", [removeSheet.title]); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width }
        SheetButtons {
            FlatButton { text: Ui.t("sticker_remove"); danger: true; onClicked: { App.removeStickerPack(removeSheet.packId); removeSheet.close() } }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: removeSheet.close() }
        }
    }

    Sheet {
        id: upload
        property url zip
        property string stage
        title: Ui.t("sticker_uploadTitle")
        Connections {
            target: App
            function onStickerUploadProgress(s) { upload.stage = s }
            function onStickerUploadDone() { upload.stage = ""; upload.close(); App.info(Ui.t("sticker_uploadDone")) }
        }
        Text { text: Ui.t("sticker_uploadRules"); color: Ui.c.textMuted; wrapMode: Text.Wrap; width: parent.width; font.pixelSize: 13 }
        Field { id: title; width: parent.width; placeholderText: Ui.t("sticker_uploadNameHint", ["50"]); maximumLength: 50 }
        FlatButton { width: parent.width; primary: false; outline: true; text: upload.zip.toString().length ? upload.zip.toString().split("/").pop() : Ui.t("sticker_uploadPick"); onClicked: zipDialog.open() }
        Text { visible: upload.stage.length > 0; text: upload.stage; color: Ui.c.textPrimary; width: parent.width; wrapMode: Text.Wrap }
        SheetButtons {
            FlatButton {
                text: Ui.t("sticker_uploadStart")
                enabled: !App.busy && title.text.trim().length > 0 && upload.zip.toString().length > 0
                onClicked: App.uploadStickerPack(title.text, upload.zip)
            }
            FlatButton { text: Ui.t("common_cancel"); primary: false; onClicked: upload.close() }
        }
        FileDialog { id: zipDialog; nameFilters: ["ZIP (*.zip)"]; onAccepted: upload.zip = selectedFile }
    }
}
