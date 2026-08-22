import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../session.dart';

class MyProfile {
  final String login;
  final String? status;
  final String? birthday;
  final int findByLoginVisibility;
  final int avatarVisibility;
  final int birthdayVisibility;
  final int statusVisibility;

  const MyProfile({
    required this.login,
    this.status,
    this.birthday,
    required this.findByLoginVisibility,
    required this.avatarVisibility,
    required this.birthdayVisibility,
    required this.statusVisibility,
  });

  MyProfile copyWith({
    String? status,
    bool clearStatus = false,
    String? birthday,
    bool clearBirthday = false,
    int? findByLoginVisibility,
    int? avatarVisibility,
    int? birthdayVisibility,
    int? statusVisibility,
  }) {
    return MyProfile(
      login: login,
      status: clearStatus ? null : (status ?? this.status),
      birthday: clearBirthday ? null : (birthday ?? this.birthday),
      findByLoginVisibility: findByLoginVisibility ?? this.findByLoginVisibility,
      avatarVisibility: avatarVisibility ?? this.avatarVisibility,
      birthdayVisibility: birthdayVisibility ?? this.birthdayVisibility,
      statusVisibility: statusVisibility ?? this.statusVisibility,
    );
  }

  Map<String, dynamic> toJson() => {
    'login': login,
    'status': status,
    'birthday': birthday,
    'find_by_login_visibility': findByLoginVisibility,
    'avatar_visibility': avatarVisibility,
    'birthday_visibility': birthdayVisibility,
    'status_visibility': statusVisibility,
  };

  static MyProfile fromJson(Map<String, dynamic> j) => MyProfile(
    login: j['login'] as String,
    status: j['status'] as String?,
    birthday: j['birthday'] as String?,
    findByLoginVisibility: j['find_by_login_visibility'] as int? ?? 1,
    avatarVisibility: j['avatar_visibility'] as int? ?? 1,
    birthdayVisibility: j['birthday_visibility'] as int? ?? 1,
    statusVisibility: j['status_visibility'] as int? ?? 1,
  );
}

/// Собственный статус/дата рождения/настройки приватности — тот же
/// паттерн, что MyAvatarStore (диск + ValueNotifier, init() один раз при
/// логине, reset() при выходе). Логин отдельно не редактируется, но
/// хранится здесь же — единая точка для всего, что показывает экран
/// "Профиль".
class MyProfileStore {
  MyProfileStore._();

  static final ValueNotifier<MyProfile?> notifier = ValueNotifier<MyProfile?>(
    null,
  );
  static bool _initStarted = false;

  static Future<File> _diskFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/my_profile_cache.json');
  }

  static Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    final token = await Session.getToken();
    if (token == null) return;

    try {
      final file = await _diskFile();
      if (await file.exists()) {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        notifier.value = MyProfile.fromJson(json);
      }
    } catch (_) {}

    final info = await ApiClient().getMyAccountInfo(token);
    if (info == null) return;
    final fresh = MyProfile(
      login: info.login,
      status: info.status,
      birthday: info.birthday,
      findByLoginVisibility: info.findByLoginVisibility,
      avatarVisibility: info.avatarVisibility,
      birthdayVisibility: info.birthdayVisibility,
      statusVisibility: info.statusVisibility,
    );
    notifier.value = fresh;
    unawaited(_writeToDisk(fresh));
  }

  static Future<void> _writeToDisk(MyProfile? profile) async {
    try {
      final file = await _diskFile();
      if (profile == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.writeAsString(jsonEncode(profile.toJson()));
    } catch (_) {}
  }

  /// Сразу после подтверждённого (ack) сохранения на сервере — см.
  /// SendQueueProcessor.onAcked в экранах профиля/приватности. Кэш
  /// обновляется ТОЛЬКО по факту подтверждения, не раньше — тот же
  /// принцип, что уже применён к read-receipts в этой сессии.
  static void setStatus(String? status) {
    final current = notifier.value;
    if (current == null) return;
    final updated = current.copyWith(status: status, clearStatus: status == null);
    notifier.value = updated;
    unawaited(_writeToDisk(updated));
  }

  static void setBirthday(String? birthday) {
    final current = notifier.value;
    if (current == null) return;
    final updated = current.copyWith(
      birthday: birthday,
      clearBirthday: birthday == null,
    );
    notifier.value = updated;
    unawaited(_writeToDisk(updated));
  }

  static void setPrivacy({
    required int findByLogin,
    required int avatar,
    required int birthday,
    required int status,
  }) {
    final current = notifier.value;
    if (current == null) return;
    final updated = current.copyWith(
      findByLoginVisibility: findByLogin,
      avatarVisibility: avatar,
      birthdayVisibility: birthday,
      statusVisibility: status,
    );
    notifier.value = updated;
    unawaited(_writeToDisk(updated));
  }

  static void reset() {
    _initStarted = false;
    notifier.value = null;
    unawaited(_writeToDisk(null));
  }
}
