import 'package:audioplayers/audioplayers.dart';

/// Централизованное место для всех звуков приложения.
class SoundService {
  static final AudioPlayer _loopPlayer = AudioPlayer();
  static final AudioPlayer _messagePlayer = AudioPlayer();

  static bool _ringbackSpeaker = false;
  static bool _ringbackPlaying = false;

  /// Гудки ожидания у звонящего проигрываются УЖЕ ПОСЛЕ того, как открыт
  /// микрофон и Android перешёл в режим голосового звонка — обычный
  /// звуковой поток (STREAM_MUSIC) в этот момент приглушается системой.
  /// AndroidUsageType.voiceCommunicationSignalling — это как раз тип
  /// звука, предназначенный Android'ом для дозвона/гудков во время
  /// активного вызова, он идёт по тому же аудио-каналу, что и сам звонок,
  /// и не приглушается.
  ///
  /// [speakerOn] пробрасывается из CallService: audioplayers при
  /// setAudioContext дёргает AudioManager.setSpeakerphoneOn(value), поэтому
  /// если оставить тут жёстко false, включённая пользователем во время
  /// дозвона громкая связь сбрасывалась бы обратно на ухо (жалоба
  /// пользователя — гудки шли не туда). При смене маршрута во время
  /// дозвона CallService зовёт [setRingbackSpeaker].
  static AudioContext _ringbackContext(bool speakerOn) => AudioContext(
    android: AudioContextAndroid(
      isSpeakerphoneOn: speakerOn,
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.voiceCommunicationSignalling,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  static Future<void> startRingback({bool speakerOn = false}) async {
    _ringbackSpeaker = speakerOn;
    _ringbackPlaying = true;
    await _loopPlayer.setAudioContext(_ringbackContext(speakerOn));
    await _loopPlayer.setReleaseMode(ReleaseMode.loop);
    await _loopPlayer.setVolume(1.0);
    await _loopPlayer.play(AssetSource('sounds/ringback.mp3'));
  }

  /// Пользователь переключил вывод (громкая связь / ухо / bluetooth) во
  /// время дозвона — перенаправляем и гудки. setAudioContext сам по себе
  /// на уже играющем плеере маршрут не меняет, поэтому перезапускаем
  /// воспроизведение (короткий, ~100 мс, разрыв в тоне — незаметно).
  static Future<void> setRingbackSpeaker(bool speakerOn) async {
    if (!_ringbackPlaying || _ringbackSpeaker == speakerOn) return;
    _ringbackSpeaker = speakerOn;
    try {
      await _loopPlayer.stop();
      await _loopPlayer.setAudioContext(_ringbackContext(speakerOn));
      await _loopPlayer.play(AssetSource('sounds/ringback.mp3'));
    } catch (_) {}
  }

  static Future<void> stopRingback() async {
    _ringbackPlaying = false;
    await _loopPlayer.stop();
  }

  static Future<void> playMessageSound() async {
    await _messagePlayer.play(AssetSource('sounds/msg_sound.mp3'));
  }
}
