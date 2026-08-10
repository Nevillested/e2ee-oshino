import 'package:shared_preferences/shared_preferences.dart';

/// Хранит реально измеренную высоту системной клавиатуры один раз на
/// весь срок жизни приложения на этом устройстве. Высота клавиатуры не
/// константа Android — зависит от установленного приложения-клавиатуры,
/// языка, доп. рядов — узнать её заранее нельзя, только измерить в
/// момент, когда клавиатура реально открылась хотя бы раз. После первого
/// измерения (в любом чате/заметках/описании) значение используется
/// везде в приложении, включая после перезапуска.
class KeyboardHeightStore {
  static const _key = 'keyboard_height_v1';
  static double? _cached;

  static Future<double> getKnownHeight({double fallback = 280}) async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_key);
    _cached = stored ?? fallback;
    return _cached!;
  }

  static Future<void> updateKnownHeight(double height) async {
    _cached = height;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, height);
  }
}