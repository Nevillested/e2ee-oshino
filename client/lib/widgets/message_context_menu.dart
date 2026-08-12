import 'dart:async';
import 'package:flutter/material.dart';
import '../storage/reaction_usage_store.dart';
import '../theme/app_theme.dart';

enum MessageMenuAction { reply, copy, pin, unpin, forward, edit, select, delete }

/// Результат закрытия контекстного меню сообщения — либо выбранное
/// действие из списка, либо поставленная реакция (эмодзи; null означает
/// "снять текущую реакцию" — повторный тап по уже стоящей своей реакции),
/// либо null (весь объект), если пользователь тапнул мимо и ничего не выбрал.
class ChatMenuSelection {
  final MessageMenuAction? action;
  final bool isReaction;
  final String? emoji;
  const ChatMenuSelection.action(this.action)
      : isReaction = false,
        emoji = null;
  const ChatMenuSelection.reaction(this.emoji) : action = null, isReaction = true;
}

const double _kMenuCellSize = 47.0;
const int _kMenuColumns = 5;
const double _kMenuWidth = _kMenuCellSize * _kMenuColumns;
const double _kActionItemHeight = 44.0;

double _safeClamp(double v, double lo, double hi) => lo >= hi ? lo : v.clamp(lo, hi);

/// Показывает контекстное меню сообщения — панель реакций сверху (см.
/// _ReactionsPanel) + список действий снизу, всплывает рядом с точкой
/// тапа, затемняя остальной экран. Возвращает выбор пользователя или
/// null, если меню закрыли, ничего не выбрав.
Future<ChatMenuSelection?> showMessageContextMenu(
  BuildContext context, {
  required Offset tapPosition,
  required bool isMine,
  required bool showCopy,
  required bool showEdit,
  required bool isPinned,
  required String? currentMyReaction,
}) {
  // Точной высоты меню заранее не знаем (зависит от того, раскрыта ли
  // панель реакций — но раскрывается она уже ПОСЛЕ открытия, без смены
  // позиции), но количество пунктов действий известно уже сейчас — оценка
  // по нему заметно точнее старой фиксированной константы.
  final actionItemCount = 5 + (showCopy ? 1 : 0) + (showEdit ? 1 : 0);
  final estimatedHeight = _kMenuCellSize + actionItemCount * _kActionItemHeight;

  final size = MediaQuery.of(context).size;
  const margin = 8.0;

  // Своё сообщение (isMine) — верхний ПРАВЫЙ угол меню стоит в точке тапа,
  // меню разворачивается вниз-влево. Чужое — верхний ЛЕВЫЙ угол в точке
  // тапа, разворот вниз-вправо. Сторона всегда определяется тем, ЧЬЁ это
  // сообщение — не оставшимся местом на экране. Если снизу не хватает
  // места — меню просто упирается в нижний край экрана (верхний угол при
  // этом оказывается выше точки тапа — это ожидаемо, не "разворот").
  final left = _safeClamp(
    isMine ? tapPosition.dx - _kMenuWidth : tapPosition.dx,
    margin,
    size.width - _kMenuWidth - margin,
  );
  final top = _safeClamp(
    tapPosition.dy,
    margin,
    size.height - estimatedHeight - margin,
  );

  final Alignment transitionAlignment = isMine ? Alignment.topRight : Alignment.topLeft;

  return showGeneralDialog<ChatMenuSelection>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'message-menu',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, anim1, anim2) {
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: _MessageContextMenuContent(
              isMine: isMine,
              showCopy: showCopy,
              showEdit: showEdit,
              isPinned: isPinned,
              currentMyReaction: currentMyReaction,
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, anim, secondaryAnim, child) {
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1.0).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOut),
          ),
          alignment: transitionAlignment,
          child: child,
        ),
      );
    },
  );
}

class _MessageContextMenuContent extends StatefulWidget {
  final bool isMine;
  final bool showCopy;
  final bool showEdit;
  final bool isPinned;
  final String? currentMyReaction;

  const _MessageContextMenuContent({
    required this.isMine,
    required this.showCopy,
    required this.showEdit,
    required this.isPinned,
    required this.currentMyReaction,
  });

  @override
  State<_MessageContextMenuContent> createState() => _MessageContextMenuContentState();
}

class _MessageContextMenuContentState extends State<_MessageContextMenuContent> {
  bool _expanded = false;
  List<String> _emojis = const [];

  @override
  void initState() {
    super.initState();
    ReactionUsageStore.getSortedEmojis().then((list) {
      if (mounted) setState(() => _emojis = list);
    });
  }

  void _pickReaction(String emoji) {
    // Повторный тап по уже стоящей своей реакции — снимает её, а не
    // ставит ту же самую заново (естественное поведение "тумблера").
    final isRemoving = emoji == widget.currentMyReaction;
    unawaited(ReactionUsageStore.recordUse(emoji));
    Navigator.of(context).pop(ChatMenuSelection.reaction(isRemoving ? null : emoji));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: _kMenuWidth,
          color: AppColors.surface,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            // ВАЖНО: единственный ребёнок этого AnimatedSize — весь Column
            // целиком, и переключение _expanded просто убирает/добавляет
            // _ActionsList из дерева напрямую (без AnimatedSwitcher). Раньше
            // тут был AnimatedSwitcher поверх _ActionsList — на время его
            // собственного fade-перехода он держал в дереве ОБА виджета
            // (старый список действий ещё утухал, новый пустой уже стоял),
            // из-за чего этот AnimatedSize видел временно завышенную высоту
            // (сетка реакций + всё ещё не пропавший список действий) и
            // анимировал панель туда, а через мгновение, когда переход
            // AnimatedSwitcher завершался и старый виджет реально исчезал из
            // дерева, высота резко проседала до настоящей целевой — отсюда
            // тот самый "вздутие и обратно" на втором шаге.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ReactionsPanel(
                  emojis: _emojis,
                  expanded: _expanded,
                  currentMyReaction: widget.currentMyReaction,
                  onToggleExpanded: () => setState(() => _expanded = !_expanded),
                  onEmojiTap: _pickReaction,
                ),
                if (!_expanded)
                  _ActionsList(
                    isMine: widget.isMine,
                    showCopy: widget.showCopy,
                    showEdit: widget.showEdit,
                    isPinned: widget.isPinned,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 1 строка (4 эмодзи + стрелка) в свёрнутом виде, 6 строк по 5 в
/// развёрнутом — прокручиваемые, если реакций больше, чем помещается.
/// Место стрелки (1 строка, 5 слот) зарезервировано за ней навсегда: она
/// нарисована ПОВЕРХ сетки отдельным непрозрачным виджетом, а не как
/// элемент списка — сетка при этом просто продолжает идти под ней, ни на
/// какую эмодзи это место специально не завязано.
class _ReactionsPanel extends StatelessWidget {
  final List<String> emojis;
  final bool expanded;
  final String? currentMyReaction;
  final VoidCallback onToggleExpanded;
  final void Function(String emoji) onEmojiTap;

  const _ReactionsPanel({
    required this.emojis,
    required this.expanded,
    required this.currentMyReaction,
    required this.onToggleExpanded,
    required this.onEmojiTap,
  });

  @override
  Widget build(BuildContext context) {
    final rows = expanded ? 6 : 1;
    return SizedBox(
      height: _kMenuCellSize * rows,
      width: _kMenuWidth,
      child: Stack(
        children: [
          GridView.builder(
            padding: EdgeInsets.zero,
            physics: expanded ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _kMenuColumns),
            itemCount: emojis.length,
            itemBuilder: (context, index) {
              final emoji = emojis[index];
              final isSelected = emoji == currentMyReaction;
              return InkWell(
                onTap: () => onEmojiTap(emoji),
                child: Container(
                  margin: const EdgeInsets.all(3),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary.withValues(alpha: 0.25) : null,
                    shape: BoxShape.circle,
                  ),
                  child: Text(emoji, style: const TextStyle(fontSize: 23)),
                ),
              );
            },
          ),
          Positioned(
            top: 0,
            right: 0,
            width: _kMenuCellSize,
            height: _kMenuCellSize,
            child: Material(
              color: AppColors.surface,
              child: InkWell(
                onTap: onToggleExpanded,
                child: Icon(
                  expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionItem {
  final IconData icon;
  final String label;
  final MessageMenuAction action;
  final Color? color;
  const _ActionItem(this.icon, this.label, this.action, {this.color});
}

class _ActionsList extends StatelessWidget {
  final bool isMine;
  final bool showCopy;
  final bool showEdit;
  final bool isPinned;

  const _ActionsList({
    required this.isMine,
    required this.showCopy,
    required this.showEdit,
    required this.isPinned,
  });

  @override
  Widget build(BuildContext context) {
    final items = <_ActionItem>[
      const _ActionItem(Icons.reply, 'Ответить', MessageMenuAction.reply),
      if (showCopy) const _ActionItem(Icons.copy_outlined, 'Копировать', MessageMenuAction.copy),
      isPinned
          ? const _ActionItem(Icons.push_pin_outlined, 'Открепить', MessageMenuAction.unpin)
          : const _ActionItem(Icons.push_pin_outlined, 'Закрепить', MessageMenuAction.pin),
      const _ActionItem(Icons.forward_outlined, 'Переслать', MessageMenuAction.forward),
      if (showEdit) const _ActionItem(Icons.edit_outlined, 'Изменить', MessageMenuAction.edit),
      const _ActionItem(Icons.check_circle_outline, 'Выбрать', MessageMenuAction.select),
      const _ActionItem(Icons.delete_outline, 'Удалить', MessageMenuAction.delete, color: Colors.redAccent),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: items
          .map(
            (item) => InkWell(
              onTap: () => Navigator.of(context).pop(ChatMenuSelection.action(item.action)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(item.icon, size: 22, color: item.color ?? AppColors.textMuted),
                    const SizedBox(width: 13),
                    Text(
                      item.label,
                      style: TextStyle(color: item.color ?? AppColors.textPrimary, fontSize: 17),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
