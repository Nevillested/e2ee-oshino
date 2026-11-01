import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Oshinobu.Core

// «Передачи»: загрузки и скачивания с прогрессом и отменой (из бокового меню и шапки чата).
Sheet {
    title: Ui.t("transfers_title")
    Repeater {
        model: App.transfers
        delegate: RowLayout {
            width: parent ? parent.width : 0
            Text { text: (modelData.kind === "upload" ? "↑ " : "↓ ") + modelData.label + " · " + modelData.peer; color: Ui.c.textPrimary; elide: Text.ElideRight; Layout.fillWidth: true }
            Text { visible: modelData.progress >= 0; text: Math.round(modelData.progress) + "%"; color: Ui.c.primary }
            IconButton { glyph: "✕"; size: 28; onClicked: App.cancelTransfer(modelData.kind, modelData.id) }
        }
    }
    Text { visible: App.transfers.length === 0; text: Ui.t("transfers_empty"); color: Ui.c.textMuted }
}
