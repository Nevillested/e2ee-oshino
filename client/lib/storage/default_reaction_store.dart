import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../data/reaction_emojis.dart';

/// Реакция по умолчанию — та, что ставится двойным тапом по сообщению.
/// У каждого пользователя своя, хранится локально на устройстве (позже
/// будет выбираться в настройках); пока настроек нет, отдаём первый эмодзи
/// из общего списка как разумное значение по умолчанию.
class DefaultReactionStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'default_reaction_emoji';

  static Future<String> get() async {
    final stored = await _storage.read(key: _key);
    return stored ?? reactionEmojis.first;
  }

  static Future<void> set(String emoji) {
    return _storage.write(key: _key, value: emoji);
  }
}
