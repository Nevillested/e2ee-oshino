import 'package:flutter/material.dart';
import '../services/keyboard_height_store.dart';
import '../theme/app_theme.dart';
import 'full_emoji_picker.dart';

class CaptionInputBar extends StatefulWidget {
  final void Function(String caption) onSend;
  const CaptionInputBar({super.key, required this.onSend});

  @override
  State<CaptionInputBar> createState() => _CaptionInputBarState();
}

class _CaptionInputBarState extends State<CaptionInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  bool _emojiMode = false;
  double _keyboardHeight = 280;

  // Целевая зарезервированная высота — меняется ТОЛЬКО в наших явных
  // обработчиках (нажатие иконки, тап по полю), никогда пассивно не
  // "плывёт" за реальной анимацией закрытия клавиатуры. Именно её
  // отсутствие раньше вызывало проседание-скачок при переключении.
  double _targetReserve = 0;
  bool _switchingMode = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    KeyboardHeightStore.getKnownHeight().then((height) {
      if (mounted) setState(() => _keyboardHeight = height);
    });
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      setState(() {
        _emojiMode = false;
        _targetReserve = _keyboardHeight;
      });
    } else {
      // unfocus(), вызванный НАМИ при переключении на эмодзи, тоже
      // порождает это событие — но раз мы уже выставили _switchingMode
      // перед вызовом unfocus(), здесь мы просто пропускаем сброс,
      // чтобы не занулить target между двумя нашими же setState.
      if (_switchingMode) {
        _switchingMode = false;
        return;
      }
      setState(() => _targetReserve = 0);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final realInset = MediaQuery.of(context).viewInsets.bottom;
    final keyboardVisible = realInset > 50;

    if (keyboardVisible && realInset > _keyboardHeight + 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _keyboardHeight = realInset);
        KeyboardHeightStore.updateKnownHeight(realInset);
      });
    }

    final emojiPanelOnlyVisible = !keyboardVisible && _emojiMode;
    // max, а не прямое следование realInset — гарантирует, что во время
    // ПЕРЕХОДА (клавиатура ещё анимированно закрывается) высота никогда
    // не проседает ниже цели, к которой мы стремимся.
    final reserved = realInset > _targetReserve ? realInset : _targetReserve;

    return PopScope(
      canPop: !emojiPanelOnlyVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && emojiPanelOnlyVisible) {
          setState(() {
            _emojiMode = false;
            _targetReserve = 0;
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: [
                  IconButton(
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      emojiPanelOnlyVisible ? Icons.keyboard : Icons.emoji_emotions_outlined,
                      color: AppColors.textMuted,
                    ),
                    onPressed: () {
                      if (emojiPanelOnlyVisible) {
                        setState(() => _emojiMode = false);
                        _focusNode.requestFocus();
                      } else {
                        _switchingMode = true;
                        _focusNode.unfocus();
                        setState(() {
                          _emojiMode = true;
                          _targetReserve = _keyboardHeight;
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      onTap: () {
                        if (_emojiMode) setState(() => _emojiMode = false);
                      },
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: const InputDecoration(
                        hintText: 'Добавьте описание',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                        hintStyle: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.send, color: AppColors.primary),
                    onPressed: () => widget.onSend(_controller.text.trim()),
                  ),
                ],
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            height: reserved,
            color: AppColors.surface,
            child: reserved > 0
                ? ClipRect(
                    child: RepaintBoundary(
                      child: FullEmojiPicker(
                        onEmojiSelected: (emoji) {
                          _controller.text += emoji;
                        },
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}