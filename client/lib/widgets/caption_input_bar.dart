import 'dart:async';
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
  static const _keyboardHeightSettleDelay = Duration(milliseconds: 180);
  Timer? _keyboardHeightSettleTimer;
  // См. build(): держит anyPanelOpen=true на те несколько кадров между
  // тапом по иконке клавиатуры (переключение из эмодзи-режима) и моментом,
  // когда настоящая клавиатура реально поднимется и realInset это заметит.
  bool _awaitingKeyboardOpen = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    KeyboardHeightStore.getKnownHeight().then((height) {
      if (mounted) setState(() => _keyboardHeight = height);
    });
  }

  void _onFocusChange() {
    // Резерв места (reserved в build()) сам вычисляется на лету из
    // keyboardVisible/_emojiMode на каждой перестройке — здесь нужно
    // только не дать эмодзи-панели остаться включённой, если фокус
    // получило текстовое поле каким-то другим путём, не через нашу кнопку.
    if (_focusNode.hasFocus && _emojiMode) {
      setState(() => _emojiMode = false);
    }
  }

  @override
  void dispose() {
    _keyboardHeightSettleTimer?.cancel();
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final realInset = MediaQuery.of(context).viewInsets.bottom;
    final keyboardVisible = realInset > 50;

    // Измеряем высоту клавиатуры только когда она перестала МЕНЯТЬСЯ — см.
    // тот же механизм и подробное объяснение в ChatScreen.build(): хватать
    // первый же кадр, где realInset превысил текущее известное значение,
    // может поймать заброс во время анимации выезда клавиатуры, а не её
    // настоящую итоговую высоту.
    if (keyboardVisible) {
      _keyboardHeightSettleTimer?.cancel();
      _keyboardHeightSettleTimer = Timer(_keyboardHeightSettleDelay, () {
        if (!mounted) return;
        final settled = MediaQuery.of(context).viewInsets.bottom;
        if (settled <= 50) return;
        if ((settled - _keyboardHeight).abs() > 1) {
          setState(() => _keyboardHeight = settled);
        }
        KeyboardHeightStore.updateKnownHeight(settled);
      });
    }

    // Клавиатура и эмодзи-панель — ОДНО и то же место, одной и той же
    // ЗАРАНЕЕ известной (закэшированной) высоты, никогда одновременно —
    // см. подробности у того же механизма в ChatScreen.build().
    if (_awaitingKeyboardOpen && keyboardVisible) {
      _awaitingKeyboardOpen = false;
    }
    // realInset — общий на всё приложение; резервируем место только если
    // клавиатуру подняло именно НАШЕ поле (см. тот же нюанс в
    // ChatScreen.build()).
    final anyPanelOpen =
        (keyboardVisible && _focusNode.hasFocus) ||
        _emojiMode ||
        _awaitingKeyboardOpen;
    final reserved = anyPanelOpen ? _keyboardHeight : 0.0;

    return PopScope(
      canPop: !_emojiMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _emojiMode) {
          setState(() => _emojiMode = false);
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
                      _emojiMode
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                      color: AppColors.textMuted,
                    ),
                    onPressed: () {
                      if (_emojiMode) {
                        _awaitingKeyboardOpen = true;
                        setState(() => _emojiMode = false);
                        _focusNode.requestFocus();
                      } else {
                        _focusNode.unfocus();
                        setState(() => _emojiMode = true);
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
          // Клавиатура и эмодзи-панель — фиксированная, заранее известная
          // высота, БЕЗ анимации (пока, по той же причине, что и в чате —
          // сначала проверяем сам механизм). Этот блок — часть Column
          // ВНУТРИ CaptionInputBar (текстовая форма выше него никогда не
          // перекрывается), а сам CaptionInputBar снаружи кладётся поверх
          // контента через Stack/Positioned(bottom: 0) — так что вырастая,
          // он не поднимает и не сжимает то, что под ним (см.
          // camera_capture_screen.dart/media_picker_sheet.dart).
          Container(
            height: reserved,
            color: AppColors.surface,
            child: _emojiMode
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
