package com.oshinobu.call_ring_plugin

import android.content.Context

/**
 * Иконка статус-бара для уведомлений о звонках. Сам drawable `ic_notification`
 * (монохромный силуэт) лежит в РЕСУРСАХ ПРИЛОЖЕНИЯ, а не этого плагин-модуля,
 * поэтому ссылаться на него через сгенерённый `R.drawable` тут нельзя —
 * достаём по имени из объединённой во время выполнения таблицы ресурсов.
 *
 * Fallback — `applicationInfo.icon` (иконка запуска): именно она раньше
 * показывалась в звонках «пустым белым кружком», потому что у launcher-иконки
 * нет плоского альфа-силуэта, которого ждёт статус-бар.
 */
internal fun Context.callNotificationIcon(): Int {
    val id = resources.getIdentifier("ic_notification", "drawable", packageName)
    return if (id != 0) id else applicationInfo.icon
}
