import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_locale.dart';
import '../l10n/app_strings.dart';

/// Язык интерфейса — хранится на устройстве, переключается сразу на весь
/// запущенный экземпляр приложения. См. ThemeStore — устроено абсолютно
/// так же (и переиспользует тот же ThemeReactive для перерисовки).
///
/// По умолчанию (свежая установка, ничего ещё не сохранено) — английский,
/// а не русский: это то, что видит любой новый пользователь при первом
/// запуске (экраны входа/регистрации и далее), независимо от локали
/// устройства.
///
/// Нарочно shared_preferences, а НЕ flutter_secure_storage (как остальные
/// такие настройки в приложении) — часть звонковых уведомлений
/// (CallRingService/OngoingCallNotifier, см. AppLocale.kt) строится
/// нативно, вообще без живого Flutter-движка, и читает этот же ключ
/// напрямую из SharedPreferences. Формат хранения shared_preferences
/// (файл "FlutterSharedPreferences", ключи с префиксом "flutter.")
/// официально документирован именно как стабильный и читаемый из
/// нативного кода — в отличие от формата flutter_secure_storage, это
/// деталь реализации плагина, на которую полагаться нельзя.
class LocaleStore {
  static const _key = 'app_locale';

  static final ValueNotifier<AppLocale> notifier = ValueNotifier(
    AppLocale.en,
  );

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    final locale = stored == 'ru' ? AppLocale.ru : AppLocale.en;
    AppStrings.locale = locale;
    notifier.value = locale;
  }

  static Future<void> setLocale(AppLocale locale) async {
    AppStrings.locale = locale;
    notifier.value = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, locale == AppLocale.en ? 'en' : 'ru');
  }
}
