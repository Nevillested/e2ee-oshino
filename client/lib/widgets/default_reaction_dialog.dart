import 'package:flutter/material.dart';
import '../data/reaction_emojis.dart';
import '../l10n/app_strings.dart';
import '../storage/default_reaction_store.dart';
import '../theme/app_theme.dart';
import 'frosted_dialog.dart';

/// Выбор реакции по умолчанию (та, что ставится двойным тапом по
/// сообщению) — сетка идёт по тому же самому reactionEmojis, что и панель
/// реакций в контекстном меню (см. ReactionUsageStore) и что и
/// message_context_menu.dart — единый список эмодзи-реакций на всё
/// приложение, определённый ровно в одном месте.
Future<void> showDefaultReactionDialog(BuildContext context) async {
  final current = await DefaultReactionStore.get();
  if (!context.mounted) return;
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => _DefaultReactionDialog(initial: current),
  );
  if (selected == null) return;
  await DefaultReactionStore.set(selected);
}

class _DefaultReactionDialog extends StatefulWidget {
  final String initial;
  const _DefaultReactionDialog({required this.initial});

  @override
  State<_DefaultReactionDialog> createState() => _DefaultReactionDialogState();
}

class _DefaultReactionDialogState extends State<_DefaultReactionDialog> {
  late String _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    return FrostedDialog(
      title: Text(
        tr('reaction.pickerTitle'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 280,
        height: 280,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 6,
          ),
          itemCount: reactionEmojis.length,
          itemBuilder: (context, index) {
            final emoji = reactionEmojis[index];
            final isSelected = emoji == _selected;
            return InkWell(
              onTap: () => setState(() => _selected = emoji),
              borderRadius: BorderRadius.circular(100),
              child: Container(
                margin: const EdgeInsets.all(2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.primary.withValues(alpha: 0.25)
                      : null,
                  shape: BoxShape.circle,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 20)),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: Text(tr('common.save')),
        ),
      ],
    );
  }
}
