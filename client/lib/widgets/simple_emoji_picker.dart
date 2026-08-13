import 'package:flutter/material.dart';
import '../data/emoji_data.dart';
import '../theme/app_theme.dart';

/// Своя лёгкая панель эмодзи — GridView.builder строит только видимые
/// на экране ячейки (а не все сразу, как делает emoji_picker_flutter),
/// а сами ячейки — простой Text без картинок/шрифтов, поэтому дешёвые
/// в отрисовке.
class SimpleEmojiPicker extends StatefulWidget {
  final void Function(String emoji) onEmojiSelected;
  const SimpleEmojiPicker({super.key, required this.onEmojiSelected});

  @override
  State<SimpleEmojiPicker> createState() => _SimpleEmojiPickerState();
}

class _SimpleEmojiPickerState extends State<SimpleEmojiPicker> {
  String _activeCategory = emojiCategories.keys.first;

  @override
  Widget build(BuildContext context) {
    final emojis = emojiCategories[_activeCategory]!;

    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: emojiCategories.keys.map((category) {
              final isActive = category == _activeCategory;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _activeCategory = category),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      category,
                      style: TextStyle(
                        color: isActive ? Colors.white : AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
            ),
            itemCount: emojis.length,
            itemBuilder: (context, index) {
              return InkWell(
                onTap: () => widget.onEmojiSelected(emojis[index]),
                child: Center(
                  child: Text(
                    emojis[index],
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
