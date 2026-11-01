import QtQuick

// Кнопки окна: прижаты вправо, не помещаются в ряд — переносятся. Порядок справа налево:
// первой пишется главная кнопка (она крайняя справа), за ней «Отмена».
Flow {
    width: parent ? parent.width : 0
    spacing: 8
    layoutDirection: Qt.RightToLeft
}
