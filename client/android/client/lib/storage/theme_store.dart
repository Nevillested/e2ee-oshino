import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../theme/app_theme.dart';

/// Тема — тёмная/светлая, хранится на устройстве и переключается сразу
/// на весь запущенный экземпляр приложения (см. ThemeReactive — им
/// обёрнуты все экраны, читающие AppColors, чтобы перерисоваться при
/// смене темы без пересоздания самих экранов и их состояния — например,
/// активный звонок или открытое WebSocket-соединение не должны обрываться
/// только потому, что пользователь в настройках переключил тему).
class ThemeStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'app_theme_mode';

  static final ValueNotifier<AppThemeMode> notifier = ValueNotifier(
    AppThemeMode.dark,
  );

  static Future<void> init() async {
    final stored = await _storage.read(key: _key);
    final mode = stored == 'light' ? AppThemeMode.light : AppThemeMode.dark;
    AppColors.mode = mode;
    notifier.value = mode;
  }

  static Future<void> setMode(AppThemeMode mode) async {
    AppColors.mode = mode;
    notifier.value = mode;
    await _storage.write(
      key: _key,
      value: mode == AppThemeMode.light ? 'light' : 'dark',
    );
  }
}
