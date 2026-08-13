import 'package:flutter/material.dart';
import '../data/emoji_data.dart';

/// Простая кастомная панель эмодзи — один сплошной список, 10 в ряд,
/// без категорий и поиска. Размер каждой ячейки считается от доступной
/// ширины экрана, чтобы всегда помещалось ровно 10 штук в ряд, независимо
/// от размера устройства.
class FullEmojiPicker extends StatelessWidget {
  final void Function(String emoji) onEmojiSelected;
  const FullEmojiPicker({super.key, required this.onEmojiSelected});

  static const int _columns = 10;

  // Список составлен из общих для Android и iOS эмодзи — используем уже
  // существующий curated-набор (emoji_data.dart), просто разворачиваем
  // все категории в один плоский список без разделения.
  static final List<String> _allEmojis = emojiCategories.values
      .expand((list) => list)
      .toList();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
      ),
      itemCount: _allEmojis.length,
      itemBuilder: (context, index) {
        return InkWell(
          onTap: () => onEmojiSelected(_allEmojis[index]),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Шрифт подстраивается под фактический размер ячейки —
              // на узких экранах эмодзи будут чуть мельче, на широких
              // (планшеты) — крупнее, но их всегда ровно 10 в ряд.
              final fontSize = constraints.maxWidth * 0.55;
              return Center(
                child: Text(
                  _allEmojis[index],
                  style: TextStyle(fontSize: fontSize),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
