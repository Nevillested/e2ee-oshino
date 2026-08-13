import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../data/reaction_emojis.dart';

/// Считает, сколько раз пользователь поставил каждую реакцию — панель
/// реакций показывает самые частые вверху списка. У свежего пользователя
/// счётчиков ещё нет, тогда просто отдаём emoji в исходном порядке
/// (порядок среди "ни разу не использованных" не имеет значения).
class ReactionUsageStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'reaction_usage_counts';

  static Future<void> recordUse(String emoji) async {
    final counts = await _readCounts();
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    await _storage.write(key: _key, value: jsonEncode(counts));
  }

  static Future<Map<String, int>> _readCounts() async {
    final stored = await _storage.read(key: _key);
    if (stored == null) return {};
    return (jsonDecode(stored) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, v as int),
    );
  }

  /// Полный список реакций, отсортированный по убыванию частоты
  /// использования — эмодзи без единого использования остаются в конце,
  /// в исходном порядке reactionEmojis.
  static Future<List<String>> getSortedEmojis() async {
    final counts = await _readCounts();
    if (counts.isEmpty) return List.of(reactionEmojis);

    final sorted = List.of(reactionEmojis);
    sorted.sort((a, b) {
      final countA = counts[a] ?? 0;
      final countB = counts[b] ?? 0;
      if (countA != countB) return countB.compareTo(countA);
      return reactionEmojis.indexOf(a).compareTo(reactionEmojis.indexOf(b));
    });
    return sorted;
  }
}
