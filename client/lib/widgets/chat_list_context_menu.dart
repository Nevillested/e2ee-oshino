import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

enum ChatListMenuAction {
  pin,
  unpin,
  mute,
  unmute,
  block,
  unblock,
  clearHistory,
  deleteChat,
}

const double _kMenuWidth = 230.0;
const double _kItemHeight = 46.0;

double _safeClamp(double v, double lo, double hi) =>
    lo >= hi ? lo : v.clamp(lo, hi);

/// Контекстное меню чата в общем списке (долгий тап по строке чата) — те же
/// 4 пункта, что в Телеге: закрепить/открепить, вкл/выкл уведомления,
/// очистить историю, удалить диалог. Визуально — тот же приём, что и
/// showMessageContextMenu (OverlayEntry, всплытие из точки тапа с блюром
/// фона), просто без панели реакций — там она не нужна.
Future<ChatListMenuAction?> showChatListContextMenu(
  BuildContext context, {
  required Offset tapPosition,
  required bool isPinned,
  required bool isMuted,
  required bool isBlocked,
}) {
  final estimatedHeight = _kItemHeight * 5;
  final mq = MediaQuery.of(context);
  final size = mq.size;
  const margin = 8.0;
  final bottomLimit = size.height - mq.viewInsets.bottom;

  final left = _safeClamp(
    tapPosition.dx,
    margin,
    size.width - _kMenuWidth - margin,
  );
  final top = _safeClamp(
    tapPosition.dy,
    margin,
    bottomLimit - estimatedHeight - margin,
  );

  final completer = Completer<ChatListMenuAction?>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _ChatListContextMenuOverlay(
      left: left,
      top: top,
      isPinned: isPinned,
      isMuted: isMuted,
      isBlocked: isBlocked,
      onClose: (result) {
        if (!completer.isCompleted) completer.complete(result);
        entry.remove();
      },
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  return completer.future;
}

class _ChatListContextMenuOverlay extends StatefulWidget {
  final double left;
  final double top;
  final bool isPinned;
  final bool isMuted;
  final bool isBlocked;
  final void Function(ChatListMenuAction? result) onClose;

  const _ChatListContextMenuOverlay({
    required this.left,
    required this.top,
    required this.isPinned,
    required this.isMuted,
    required this.isBlocked,
    required this.onClose,
  });

  @override
  State<_ChatListContextMenuOverlay> createState() =>
      _ChatListContextMenuOverlayState();
}

class _ChatListContextMenuOverlayState
    extends State<_ChatListContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  void _close(ChatListMenuAction? result) {
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
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastOutSlowIn,
    );
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
              alignment: Alignment.topLeft,
              child: _ChatListMenuContent(
                isPinned: widget.isPinned,
                isMuted: widget.isMuted,
                isBlocked: widget.isBlocked,
                onSelect: _close,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuItem {
  final IconData icon;
  final String label;
  final ChatListMenuAction action;
  final Color? color;
  const _MenuItem(this.icon, this.label, this.action, {this.color});
}

class _ChatListMenuContent extends StatelessWidget {
  final bool isPinned;
  final bool isMuted;
  final bool isBlocked;
  final void Function(ChatListMenuAction action) onSelect;

  const _ChatListMenuContent({
    required this.isPinned,
    required this.isMuted,
    required this.isBlocked,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final items = <_MenuItem>[
      isPinned
          ? _MenuItem(
              Icons.push_pin_outlined,
              tr('chatMenu.unpin'),
              ChatListMenuAction.unpin,
            )
          : _MenuItem(
              Icons.push_pin_outlined,
              tr('chatMenu.pin'),
              ChatListMenuAction.pin,
            ),
      isMuted
          ? _MenuItem(
              Icons.notifications_active_outlined,
              tr('chatMenu.unmute'),
              ChatListMenuAction.unmute,
            )
          : _MenuItem(
              Icons.notifications_off_outlined,
              tr('chatMenu.mute'),
              ChatListMenuAction.mute,
            ),
      isBlocked
          ? _MenuItem(
              Icons.block,
              tr('chatMenu.unblock'),
              ChatListMenuAction.unblock,
            )
          : _MenuItem(
              Icons.block,
              tr('chatMenu.block'),
              ChatListMenuAction.block,
              color: Colors.redAccent,
            ),
      _MenuItem(
        Icons.cleaning_services_outlined,
        tr('chatMenu.clearHistory'),
        ChatListMenuAction.clearHistory,
      ),
      _MenuItem(
        Icons.delete_outline,
        tr('chatMenu.deleteChat'),
        ChatListMenuAction.deleteChat,
        color: Colors.redAccent,
      ),
    ];

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: _kMenuWidth,
          color: AppColors.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: items
                .map(
                  (item) => InkWell(
                    onTap: () => onSelect(item.action),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            item.icon,
                            size: 21,
                            color: item.color ?? AppColors.textMuted,
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Text(
                              item.label,
                              style: TextStyle(
                                color: item.color ?? AppColors.textPrimary,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}
