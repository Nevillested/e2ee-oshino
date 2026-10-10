import 'package:flutter/foundation.dart';

/// Единая точка координации проигрывания голосовых/видео-сообщений внутри
/// ОДНОГО открытого чата (см. ТЗ пользователя — верхняя панель управления,
/// общая для голосовых и видео-кружков). Каждый VideoNotePlayer/
/// VoiceMessagePlayer, начиная проигрывание, регистрирует себя здесь
/// (activate) вместе с тремя колбэками управления — pause/resume/stop —
/// а верхняя панель дёргает их, вообще не зная, voice это или video: вся
/// специфика конкретного плеера спрятана внутри самих колбэков.
///
/// Один экземпляр на ChatScreen (создаётся в initState, уничтожается в
/// dispose) — воспроизведение не переживает уход с экрана чата, как и
/// раньше (у самих плееров уже был dispose(), останавливающий контроллер).
class MediaPlaybackCoordinator extends ChangeNotifier {
  String? activeMessageId;
  bool isPlaying = false;
  VoidCallback? _pause;
  VoidCallback? _resume;
  VoidCallback? _stop;

  void activate(
    String messageId, {
    required VoidCallback pause,
    required VoidCallback resume,
    required VoidCallback stop,
  }) {
    // Если играло что-то ДРУГОЕ — полностью останавливаем его (как по
    // крестику), прежде чем стать новым активным: панель одна на экран,
    // одновременно "видимыми" в ней двух разных сообщений быть не должно.
    if (activeMessageId != null && activeMessageId != messageId) {
      _stop?.call();
    }
    activeMessageId = messageId;
    isPlaying = true;
    _pause = pause;
    _resume = resume;
    _stop = stop;
    notifyListeners();
  }

  /// Плеер сообщает о смене своего состояния play/pause БЕЗ смены того,
  /// какое сообщение активно (обычная пауза кнопкой на самом пузыре, или
  /// естественное завершение проигрывания) — панель остаётся видимой,
  /// просто меняется иконка.
  void reportPlaying(String messageId, bool playing) {
    if (activeMessageId != messageId || isPlaying == playing) return;
    isPlaying = playing;
    notifyListeners();
  }

  /// Сообщение перестало быть "активным" полностью — либо явный крестик на
  /// панели, либо сам плеер ушёл из дерева (dispose) пока был активным.
  void deactivate(String messageId) {
    if (activeMessageId != messageId) return;
    activeMessageId = null;
    isPlaying = false;
    _pause = null;
    _resume = null;
    _stop = null;
    notifyListeners();
  }

  void togglePlayPause() {
    if (isPlaying) {
      _pause?.call();
    } else {
      _resume?.call();
    }
  }

  void close() => _stop?.call();
}
