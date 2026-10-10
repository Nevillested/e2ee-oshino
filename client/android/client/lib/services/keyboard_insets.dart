import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'debug_log.dart';

/// Обходит подтверждённый баг рассинхронизации MediaQuery.viewInsets с
/// настоящей клавиатурой на Android (edge-to-edge + системный back-жест —
/// см. flutter/flutter#168768 и связанные issues #89914/#131152/#116836).
/// В этом сценарии Flutter либо зависает на старом значении inset'а, либо
/// доставляет его одним прыжком заметно позже настоящей системной
/// анимации — никакая доводка на стороне Dart (несколько попыток за эту
/// сессию — см. историю правок chat_screen.dart) этого не чинит, потому
/// что сам источник данных ненадёжен.
///
/// Вместо MediaQuery здесь — прямой канал с нативной стороны
/// (MainActivity.kt: WindowInsetsAnimationCallback + OnApplyWindowInsetsListener),
/// которая читает высоту IME напрямую у системы, покадрово, включая
/// промежуточные значения во время самой системной анимации. iOS этот
/// канал пока не реализует (нативная сторона там его просто не заводит) —
/// heightPx на iOS всегда останется 0, вызывающая сторона должна сама
/// откатываться на обычный MediaQuery.viewInsets в этом случае (см.
/// isActive).
class KeyboardInsets {
  KeyboardInsets._();

  static const _channel = EventChannel('oshinobu/keyboard_insets');

  /// Живая высота клавиатуры в АППАРАТНЫХ пикселях (не логических!) —
  /// нативная сторона отдаёт как есть, конвертация в логические пиксели
  /// (через devicePixelRatio) — на вызывающей стороне, там уже есть
  /// подходящий BuildContext под рукой.
  static final ValueNotifier<double> heightPx = ValueNotifier<double>(0);

  /// true, если хотя бы одно событие от нативной стороны уже пришло — до
  /// этого момента heightPx==0 неотличим от "клавиатуры действительно нет"
  /// и от "канал ещё не отчитался ни разу" (например, платформа его не
  /// реализует вообще, как сейчас iOS). Вызывающая сторона использует это,
  /// чтобы не подменять MediaQuery этим источником, пока он не доказал, что
  /// реально жив.
  static bool isActive = false;

  /// Логические пиксели — тот же приём, что и в ChatScreen (единственном
  /// месте, откуда этот механизм изначально пошёл): если нативный канал
  /// уже доказал, что жив (isActive), используем его вместо
  /// MediaQuery.viewInsets.bottom — тот самый ненадёжный источник, который
  /// весь этот класс и обходит. На iOS/пока канал не отчитался ни разу —
  /// честный откат на обычный MediaQuery.
  ///
  /// ТЗ пользователя: тот же самый механизм нужен не только композеру чата,
  /// но и панели подписи к медиа (CaptionInputBar) — вынесено сюда, чтобы
  /// не дублировать формулу в каждом месте использования.
  static double resolveInsetPx(BuildContext context) {
    if (isActive) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      if (dpr > 0) return heightPx.value / dpr;
    }
    return MediaQuery.of(context).viewInsets.bottom;
  }

  static StreamSubscription<dynamic>? _sub;
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    _sub = _channel.receiveBroadcastStream().listen(
      (event) {
        if (event is num) {
          isActive = true;
          heightPx.value = event.toDouble();
        }
      },
      onError: (Object e, StackTrace st) {
        DebugLog.log('KeyboardInsets: stream error: $e');
      },
      cancelOnError: false,
    );
  }

  /// Не вызывается нигде за пределами тестов — сервис живёт всю сессию
  /// приложения, как и остальные подобные (WebSocketService и т.п.).
  /// Оставлен для симметрии/на случай будущих тестов.
  @visibleForTesting
  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
    isActive = false;
    heightPx.value = 0;
  }
}
