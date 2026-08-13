import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Реакция по умолчанию — та, что ставится двойным тапом по сообщению.
/// У каждого пользователя своя, хранится локально на устройстве, выбирается
/// в настройках (см. default_reaction_dialog.dart); пока пользователь ни
/// разу не выбрал свою — 👍, а не первый эмодзи из общего пула: после
/// объединения пула с полным списком emoji_data.dart (см. reaction_emojis.dart)
/// первым там оказывается 😀 — 👍 как реакция по умолчанию понятнее.
class DefaultReactionStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'default_reaction_emoji';
  static const _fallback = '👍';

  static Future<String> get() async {
    final stored = await _storage.read(key: _key);
    return stored ?? _fallback;
  }

  static Future<void> set(String emoji) {
    return _storage.write(key: _key, value: emoji);
  }
}
