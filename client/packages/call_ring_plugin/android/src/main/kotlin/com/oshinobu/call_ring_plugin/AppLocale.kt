package com.oshinobu.call_ring_plugin

import android.content.Context

/**
 * Язык интерфейса, выбранный на Dart-стороне (см. lib/storage/locale_store.dart)
 * — читаем его здесь напрямую из SharedPreferences, а не через platform
 * channel, потому что часть уведомлений (звонок при полностью закрытом
 * приложении — CallRingService/OngoingCallNotifier) строится нативно, БЕЗ
 * живого Flutter-движка вообще, и достучаться до канала попросту не до
 * кого. LocaleStore нарочно хранит язык через shared_preferences (а не
 * flutter_secure_storage, как остальные настройки) — именно ради этого:
 * формат хранения shared_preferences (файл "FlutterSharedPreferences",
 * ключи с префиксом "flutter.") официально документирован и стабилен
 * специально для чтения из нативного кода, в отличие от
 * flutter_secure_storage, чей формат — деталь реализации плагина.
 */
object AppLocale {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY = "flutter.app_locale"

    fun isRussian(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY, "en") == "ru"
    }
}
