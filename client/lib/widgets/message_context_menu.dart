import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../storage/reaction_usage_store.dart';
import '../theme/app_theme.dart';

enum MessageMenuAction {
  reply,
  copy,
  pin,
  unpin,
  forward,
  edit,
  select,
  delete,
}

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
  const ChatMenuSelection.reaction(this.emoji)
    : action = null,
      isReaction = true;
}

const double _kMenuCellSize = 47.0;
const int _kMenuColumns = 5;
const double _kMenuWidth = _kMenuCellSize * _kMenuColumns;
const double _kActionItemHeight = 44.0;

double _safeClamp(double v, double lo, double hi) =>
    lo >= hi ? lo : v.clamp(lo, hi);

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
  // Вызывается один раз сразу после открытия меню с функцией его
  // анимированного закрытия — нужно вызывающей стороне (ChatScreen), чтобы
  // системная кнопка "назад" сначала закрывала меню, а не сразу уходила
  // из чата (само меню больше не Navigator route и на back не реагирует).
  void Function(VoidCallback closeMenu)? onOpened,
}) {
  // Точной высоты меню заранее не знаем (зависит от того, раскрыта ли
  // панель реакций — но раскрывается она уже ПОСЛЕ открытия, без смены
  // позиции), но количество пунктов действий известно уже сейчас — оценка
  // по нему заметно точнее старой фиксированной константы.
  final actionItemCount = 5 + (showCopy ? 1 : 0) + (showEdit ? 1 : 0);
  final estimatedHeight = _kMenuCellSize + actionItemCount * _kActionItemHeight;

  final mq = MediaQuery.of(context);
  final size = mq.size;
  const margin = 8.0;

  // Меню — по сути тупиковая, самая верхняя точка экрана: должно
  // перекрывать вообще всё, включая открытую клавиатуру, а не проваливаться
  // под неё. Отрисоваться физически ПОВЕРХ системной клавиатуры Flutter не
  // может (это отдельная системная поверхность), но может — и должно —
  // никогда не залезать своими границами в занятую ей область: нижняя
  // граница меню считается от границы с клавиатурой (mq.viewInsets.bottom),
  // а не от полной высоты экрана, как было раньше — из-за чего меню могло
  // частично оказаться в зоне, которую клавиатура рисует поверх.
  final bottomLimit = size.height - mq.viewInsets.bottom;

  // Своё сообщение (isMine) — верхний ПРАВЫЙ угол меню стоит в точке тапа,
  // меню разворачивается вниз-влево. Чужое — верхний ЛЕВЫЙ угол в точке
  // тапа, разворот вниз-вправо. Сторона всегда определяется тем, ЧЬЁ это
  // сообщение — не оставшимся местом на экране. Если снизу не хватает
  // места — меню просто упирается в нижний край (свободной от клавиатуры
  // области) экрана (верхний угол при этом оказывается выше точки тапа —
  // это ожидаемо, не "разворот").
  final left = _safeClamp(
    isMine ? tapPosition.dx - _kMenuWidth : tapPosition.dx,
    margin,
    size.width - _kMenuWidth - margin,
  );
  final top = _safeClamp(
    tapPosition.dy,
    margin,
    bottomLimit - estimatedHeight - margin,
  );

  final completer = Completer<ChatMenuSelection?>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _MessageContextMenuOverlay(
      left: left,
      top: top,
      isMine: isMine,
      showCopy: showCopy,
      showEdit: showEdit,
      isPinned: isPinned,
      currentMyReaction: currentMyReaction,
      onOpened: onOpened,
      onClose: (result) {
        if (!completer.isCompleted) completer.complete(result);
        entry.remove();
      },
    ),
  );

  // OverlayEntry, а НЕ showGeneralDialog/Navigator route — сознательно.
  // Пуш НОВОГО route в Navigator меняет владельца фокуса приложения:
  // именно это (а не наш собственный ручной unfocus(), который убирали
  // раньше) было настоящей причиной того, что клавиатура/эмодзи-панель
  // сами закрывались при открытии меню и сами открывались обратно при
  // его закрытии — Flutter переключает FocusScope между route при
  // каждом push/pop независимо от параметра requestFocus (он влияет
  // только на то, забирает ли фокус СЕБЕ сам новый route, а не на то,
  // что происходит с фокусом СТАРОГО route, когда он перестаёт быть
  // текущим). OverlayEntry никакой отдельный route не создаёт и вообще
  // не участвует в этом механизме — фокус на текстовом поле чата все
  // это время остаётся ровно там, где был.
  Overlay.of(context, rootOverlay: true).insert(entry);

  return completer.future;
}

class _MessageContextMenuOverlay extends StatefulWidget {
  final double left;
  final double top;
  final bool isMine;
  final bool showCopy;
  final bool showEdit;
  final bool isPinned;
  final String? currentMyReaction;
  final void Function(VoidCallback closeMenu)? onOpened;
  final void Function(ChatMenuSelection? result) onClose;

  const _MessageContextMenuOverlay({
    required this.left,
    required this.top,
    required this.isMine,
    required this.showCopy,
    required this.showEdit,
    required this.isPinned,
    required this.currentMyReaction,
    required this.onOpened,
    required this.onClose,
  });

  @override
  State<_MessageContextMenuOverlay> createState() =>
      _MessageContextMenuOverlayState();
}

class _MessageContextMenuOverlayState
    extends State<_MessageContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  // Вдвое быстрее предыдущего показа (было 700мс).
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    widget.onOpened?.call(() => _close(null));
  }

  void _close(ChatMenuSelection? result) {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(() => widget.onClose(result));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Вариант 7 из перебора — масштаб от 0.3 из точки тапа + фейд (как в
    // v6), но теперь ЕЩЁ и фон за меню плавно РАЗМЫВАЕТСЯ (BackdropFilter,
    // сигма растёт вместе с анимацией) — тот самый эффект "в стиле
    // Cupertino-меню", но без перестройки самого жеста/позиционирования.
    // (v1 — масштаб плавно; v2 — масштаб-пружинка; v3 — сдвиг из угла;
    // v4 — чистый фейд; v5 — лёгкий поворот из угла; v6 — резкий хлопок
    // без блюра.)
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastOutSlowIn,
    );
    final popAlignment = widget.isMine ? Alignment.topRight : Alignment.topLeft;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _close(null),
            child: AnimatedBuilder(
              animation: curved,
              builder: (context, _) {
                final sigma = 4.0 * curved.value;
                return BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
        Positioned(
          left: widget.left,
          top: widget.top,
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.3, end: 1.0).animate(curved),
              alignment: popAlignment,
              child: _MessageContextMenuContent(
                isMine: widget.isMine,
                showCopy: widget.showCopy,
                showEdit: widget.showEdit,
                isPinned: widget.isPinned,
                currentMyReaction: widget.currentMyReaction,
                onSelect: _close,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageContextMenuContent extends StatefulWidget {
  final bool isMine;
  final bool showCopy;
  final bool showEdit;
  final bool isPinned;
  final String? currentMyReaction;
  final void Function(ChatMenuSelection selection) onSelect;

  const _MessageContextMenuContent({
    required this.isMine,
    required this.showCopy,
    required this.showEdit,
    required this.isPinned,
    required this.currentMyReaction,
    required this.onSelect,
  });

  @override
  State<_MessageContextMenuContent> createState() =>
      _MessageContextMenuContentState();
}

class _MessageContextMenuContentState
    extends State<_MessageContextMenuContent> {
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
    widget.onSelect(ChatMenuSelection.reaction(isRemoving ? null : emoji));
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
                  onToggleExpanded: () =>
                      setState(() => _expanded = !_expanded),
                  onEmojiTap: _pickReaction,
                ),
                if (!_expanded)
                  _ActionsList(
                    isMine: widget.isMine,
                    showCopy: widget.showCopy,
                    showEdit: widget.showEdit,
                    isPinned: widget.isPinned,
                    onSelect: widget.onSelect,
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
            physics: expanded
                ? const ClampingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _kMenuColumns,
            ),
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
                    color: isSelected
                        ? AppColors.primary.withValues(alpha: 0.25)
                        : null,
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
                  expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
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
  final void Function(ChatMenuSelection selection) onSelect;

  const _ActionsList({
    required this.isMine,
    required this.showCopy,
    required this.showEdit,
    required this.isPinned,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final items = <_ActionItem>[
      const _ActionItem(Icons.reply, 'Ответить', MessageMenuAction.reply),
      if (showCopy)
        const _ActionItem(
          Icons.copy_outlined,
          'Копировать',
          MessageMenuAction.copy,
        ),
      isPinned
          ? const _ActionItem(
              Icons.push_pin_outlined,
              'Открепить',
              MessageMenuAction.unpin,
            )
          : const _ActionItem(
              Icons.push_pin_outlined,
              'Закрепить',
              MessageMenuAction.pin,
            ),
      const _ActionItem(
        Icons.forward_outlined,
        'Переслать',
        MessageMenuAction.forward,
      ),
      if (showEdit)
        const _ActionItem(
          Icons.edit_outlined,
          'Изменить',
          MessageMenuAction.edit,
        ),
      const _ActionItem(
        Icons.check_circle_outline,
        'Выбрать',
        MessageMenuAction.select,
      ),
      const _ActionItem(
        Icons.delete_outline,
        'Удалить',
        MessageMenuAction.delete,
        color: Colors.redAccent,
      ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: items
          .map(
            (item) => InkWell(
              onTap: () => onSelect(ChatMenuSelection.action(item.action)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 22,
                      color: item.color ?? AppColors.textMuted,
                    ),
                    const SizedBox(width: 13),
                    Text(
                      item.label,
                      style: TextStyle(
                        color: item.color ?? AppColors.textPrimary,
                        fontSize: 17,
                      ),
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
