import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../services/keyboard_height_store.dart';
import '../services/keyboard_insets.dart';
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
    // См. KeyboardInsets/ChatScreen — тот же нативный источник высоты
    // клавиатуры (ТЗ пользователя: "сделай тоже самое, что и в чате").
    // ValueNotifier сам по себе не встроен в дерево виджетов, перестройку
    // по его изменению нужно попросить явно.
    KeyboardInsets.heightPx.addListener(_onKeyboardInsetsChanged);
  }

  void _onKeyboardInsetsChanged() {
    if (mounted) setState(() {});
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
    KeyboardInsets.heightPx.removeListener(_onKeyboardInsetsChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final realInset = KeyboardInsets.resolveInsetPx(context);
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
        final settled = KeyboardInsets.resolveInsetPx(context);
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
    // РЕАЛЬНЫЙ баг (жалоба пользователя: "поднимается не так же плавно,
    // как панель сообщения в чате") — раньше reserved скачком принимал
    // фиксированное закэшированное _keyboardHeight целиком, в тот же кадр,
    // что и anyPanelOpen становился true, вместо того чтобы плавно
    // следовать за живой, покадровой анимацией настоящей клавиатуры (см.
    // realInset — тот самый нативный источник, см. KeyboardInsets). Тот же
    // приём, что и в ChatScreen.build(): для НАСТОЯЩЕЙ клавиатуры резерв —
    // это сам realInset (растёт/убывает вместе с ней, кадр в кадр), а
    // _keyboardHeight используется только как компенсация ПОКА идёт переход
    // клавиатура<->эмодзи-панель (emojiReserved) — эмодзи-панель не
    // системная, живого сигнала анимации у неё в принципе нет, но сумма
    // realInset+emojiReserved всё равно всегда равна _keyboardHeight, без
    // единого скачка на стыке.
    final realOnly = (keyboardVisible && _focusNode.hasFocus) ? realInset : 0.0;
    final emojiReserved = (_emojiMode || _awaitingKeyboardOpen)
        ? (_keyboardHeight - realInset).clamp(0.0, _keyboardHeight)
        : 0.0;
    final reserved = realOnly + emojiReserved;

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
                      style: TextStyle(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: tr('chat.captionHint'),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                        hintStyle: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.send, color: AppColors.primary),
                    onPressed: () => widget.onSend(_controller.text.trim()),
                  ),
                ],
              ),
            ),
          ),
          // Системный отступ до жестовой/3-кнопочной зоны — тот же приём,
          // что в ChatScreen.build() (viewPadding, а не padding — тот
          // зануляется настоящей клавиатурой, но НЕ нашей эмодзи-панелью,
          // и тогда высота эмодзи-панели разъезжалась бы с клавиатурой).
          // Раньше эта панель (см. media_picker_sheet.dart/
          // camera_capture_screen.dart — превью фото с подписью перед
          // отправкой) была вообще БЕЗ этого отступа: на 3-кнопочной
          // навигации (Samsung) системная панель перекрывала поле ввода
          // подписи целиком — жалоба тестера с логом systemBottomInset,
          // который для обычного композера в чате уже учитывался, а для
          // этого экрана — нет.
          SizedBox(
            height: anyPanelOpen
                ? 0
                : MediaQuery.of(context).viewPadding.bottom,
          ),
          // reserved (см. её вычисление выше) — либо живой realInset
          // (настоящая клавиатура, кадр в кадр её собственной системной
          // анимации), либо закэшированная _keyboardHeight (эмодзи-панель —
          // не системная, живого сигнала у неё нет). Этот блок — часть
          // Column ВНУТРИ CaptionInputBar (текстовая форма выше него
          // никогда не перекрывается), а сам CaptionInputBar снаружи
          // кладётся поверх контента через Stack/Positioned(bottom: 0) —
          // так что вырастая, он не поднимает и не сжимает то, что под ним
          // (см. camera_capture_screen.dart/media_picker_sheet.dart).
          Container(
            height: reserved,
            color: AppColors.surface,
            // Тот же приём, что и в ChatScreen: пока клавиатура поднята,
            // держим FullEmojiPicker уже смонтированным, но невидимым
            // (Offstage) — тап по иконке эмодзи тогда просто переключает
            // видимость, а не строит панель с нуля.
            child: (_emojiMode || keyboardVisible)
                ? Offstage(
                    offstage: !_emojiMode,
                    child: ClipRect(
                      child: RepaintBoundary(
                        child: FullEmojiPicker(
                          onEmojiSelected: (emoji) {
                            _controller.text += emoji;
                          },
                        ),
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
