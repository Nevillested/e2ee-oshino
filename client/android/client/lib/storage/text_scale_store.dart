import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Масштаб текста интерфейса — хранится на устройстве, применяется сразу
/// на весь запущенный экземпляр приложения через MediaQuery.textScaler в
/// _App (main.dart), тем же способом, что ThemeStore/LocaleStore
/// применяются через AnimatedBuilder. 1.0 — то, что зашито в приложении по
/// умолчанию (ничего не меняется, если пользователь никогда не заходил в
/// настройку).
class TextScaleStore {
  static const _key = 'app_text_scale';

  /// Шесть шагов вокруг встроенного по умолчанию размера (1.0) — три
  /// меньше, два крупнее, сам 1.0 посередине.
  static const List<double> steps = [0.85, 0.9, 1.0, 1.1, 1.2, 1.3];

  static final ValueNotifier<double> notifier = ValueNotifier(1.0);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_key);
    notifier.value = stored != null && steps.contains(stored) ? stored : 1.0;
  }

  static Future<void> setScale(double scale) async {
    notifier.value = scale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, scale);
  }
}
