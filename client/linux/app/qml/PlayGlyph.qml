import QtQuick

// Значок «играть» / «пауза», нарисованный (символ ▶ шрифт подменяет цветным эмодзи).
Canvas {
    id: g
    property bool paused: false // true — рисуется пауза
    property color color: "white"
    implicitWidth: 16
    implicitHeight: 16
    onPausedChanged: requestPaint()
    onColorChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = color
        if (paused) {
            const w = width * 0.3
            ctx.fillRect(width * 0.12, 0, w, height)
            ctx.fillRect(width * 0.58, 0, w, height)
        } else {
            ctx.beginPath()
            ctx.moveTo(width * 0.12, 0)
            ctx.lineTo(width, height / 2)
            ctx.lineTo(width * 0.12, height)
            ctx.closePath()
            ctx.fill()
        }
    }
}
