import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/avatar_cache.dart';
import 'avatar_settings_tile.dart';

/// Фото профиля через AvatarCache — НЕ FutureBuilder(future: AvatarCache.
/// get(...)), тот всегда на первый кадр рисует "нет данных", даже если
/// байты уже лежат в памяти (см. AvatarCache.peek) — при пересоздании
/// виджета несколько раз подряд (ровно то, что делает Hero-полёт при
/// zoom-переходе в профиль, см. chat_screen.dart/peer_profile_screen.dart)
/// это давало заметное мелькание плейсхолдера поверх уже загруженного
/// фото. Тут initState читает peek() синхронно ДО первого build — если
/// что-то уже есть в памяти, никакого "пустого" кадра не будет вовсе.
class CachedAvatarImage extends StatefulWidget {
  final String accountId;
  final double radius;

  const CachedAvatarImage({
    super.key,
    required this.accountId,
    required this.radius,
  });

  @override
  State<CachedAvatarImage> createState() => _CachedAvatarImageState();
}

class _CachedAvatarImageState extends State<CachedAvatarImage> {
  Uint8List? _bytes;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _bytes = AvatarCache.peek(widget.accountId);
    if (_bytes == null) _fetch(widget.accountId);
    _listen();
  }

  void _listen() {
    _sub = AvatarCache.changes.listen((id) {
      if (id != widget.accountId || !mounted) return;
      setState(() => _bytes = AvatarCache.peek(id));
    });
  }

  Future<void> _fetch(String accountId) async {
    final bytes = await AvatarCache.get(accountId);
    if (!mounted || accountId != widget.accountId) return;
    setState(() => _bytes = bytes);
  }

  @override
  void didUpdateWidget(covariant CachedAvatarImage old) {
    super.didUpdateWidget(old);
    if (old.accountId != widget.accountId) {
      _bytes = AvatarCache.peek(widget.accountId);
      if (_bytes == null) _fetch(widget.accountId);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipOval(
    // Явное обрезание по кругу поверх и без того круглого CircleAvatar —
    // защита конкретно для Hero-полёта (см. peer_avatar Hero в
    // chat_screen.dart/peer_profile_screen.dart): во время анимации между
    // сильно разными размерами (radius 16 → 64) на долю секунды был виден
    // прямоугольный "хвост" непроклипованного кадра позади уже видимого
    // круга. ClipOval гарантирует, что за пределы круга ничего не
    // просочится вообще, независимо от того, что там происходит внутри
    // во время перелёта.
    child: AvatarThumbnail(bytes: _bytes, radius: widget.radius),
  );
}
