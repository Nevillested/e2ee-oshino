import 'package:audioplayers/audioplayers.dart';

/// Централизованное место для всех звуков приложения.
class SoundService {
  static final AudioPlayer _loopPlayer = AudioPlayer();
  static final AudioPlayer _messagePlayer = AudioPlayer();

  /// Гудки ожидания у звонящего проигрываются УЖЕ ПОСЛЕ того, как открыт
  /// микрофон и Android перешёл в режим голосового звонка — обычный
  /// звуковой поток (STREAM_MUSIC) в этот момент приглушается системой.
  /// AndroidUsageType.voiceCommunicationSignalling — это как раз тип
  /// звука, предназначенный Android'ом для дозвона/гудков во время
  /// активного вызова, он идёт по тому же аудио-каналу, что и сам звонок,
  /// и не приглушается.
  static final _callSignallingContext = AudioContext(
    android: AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.voiceCommunicationSignalling,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  static Future<void> startRingback() async {
    await _loopPlayer.setAudioContext(_callSignallingContext);
    await _loopPlayer.setReleaseMode(ReleaseMode.loop);
    await _loopPlayer.setVolume(1.0);
    await _loopPlayer.play(AssetSource('sounds/ringback.mp3'));
  }

  static Future<void> startRingtone() async {
    // У принимающего микрофон ещё не открыт — можно проигрывать обычным
    // способом, по умолчанию.
    await _loopPlayer.setReleaseMode(ReleaseMode.loop);
    await _loopPlayer.setVolume(1.0);
    await _loopPlayer.play(AssetSource('sounds/ringtone.mp3'));
  }

  static Future<void> stopRingback() async {
    await _loopPlayer.stop();
  }

  static Future<void> stopRingtone() async {
    await _loopPlayer.stop();
  }

  static Future<void> playMessageSound() async {
    await _messagePlayer.play(AssetSource('sounds/msg_sound.mp3'));
  }
}