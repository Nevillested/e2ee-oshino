import 'dart:async';
import 'package:flutter/material.dart';
import '../services/peer_profile_cache.dart';

/// Текст с отображаемым именем собеседника (см. ТЗ пользователя:
/// display_name, если задан, иначе login — везде, где раньше показывался
/// голый login). Тот же паттерн, что у CachedAvatarImage — сам резолвит и
/// кэширует значение через PeerProfileCache (get() уже сам эффективно
/// кэширует по accountId — на списках из многих строк лишних сетевых
/// запросов не будет), сам живо перестраивается по PeerProfileCache.changes.
class PeerNameText extends StatefulWidget {
  final String accountId;
  final String fallbackLogin;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  const PeerNameText({
    super.key,
    required this.accountId,
    required this.fallbackLogin,
    this.style,
    this.maxLines,
    this.overflow,
  });

  @override
  State<PeerNameText> createState() => _PeerNameTextState();
}

class _PeerNameTextState extends State<PeerNameText> {
  String? _name;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = PeerProfileCache.changes.listen((accountId) {
      if (accountId == widget.accountId) _load();
    });
  }

  @override
  void didUpdateWidget(covariant PeerNameText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) {
      _name = null;
      _load();
    }
  }

  Future<void> _load() async {
    final profile = await PeerProfileCache.get(
      widget.accountId,
      widget.fallbackLogin,
    );
    if (!mounted) return;
    final name = profile?.displayName ?? widget.fallbackLogin;
    if (name != _name) setState(() => _name = name);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _name ?? widget.fallbackLogin,
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
