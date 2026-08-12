import 'package:shared_preferences/shared_preferences.dart';

/// Позиция прокрутки чата — на каком сообщении пользователь остановился в
/// последний раз, чтобы при следующем входе (в том числе после полного
/// перезапуска приложения — раньше это хранилось только в оперативной
/// памяти процесса и слетало при закрытии) открыть чат ровно в этом же
/// месте, а не всегда внизу.
class ChatScrollPositionStore {
  static String _key(String peerLogin) => 'chat_scroll_pos:$peerLogin';

  static Future<double?> get(String peerLogin) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_key(peerLogin));
  }

  static Future<void> set(String peerLogin, double offset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key(peerLogin), offset);
  }
}
