import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../services/avatar_cache.dart';
import '../services/peer_profile_cache.dart';
import '../theme/app_theme.dart';
import '../widgets/cached_avatar_image.dart';
import '../widgets/photo_viewer_screen.dart';
import '../widgets/theme_reactive.dart';

/// Профиль ЧУЖОГО пользователя, read-only — открывается zoom-переходом
/// (см. HeroZoomPageRoute) по тапу на кластер аватар+логин в шапке чата.
/// Поля, к которым у смотрящего нет доступа (приватность собеседника),
/// сервер просто не прислал (см. account_profile.go) — здесь их либо нет
/// вообще, либо "не указано"/пусто, отдельно объяснять почему не нужно.
class PeerProfileScreen extends StatefulWidget {
  final String peerAccountId;
  final String peerLogin;

  const PeerProfileScreen({
    super.key,
    required this.peerAccountId,
    required this.peerLogin,
  });

  @override
  State<PeerProfileScreen> createState() => _PeerProfileScreenState();
}

class _PeerProfileScreenState extends State<PeerProfileScreen> {
  PeerProfile? _profile;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await PeerProfileCache.get(
      widget.peerAccountId,
      widget.peerLogin,
    );
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton(
                icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              // ВАЖНО: Hero с аватаром (и всё, что не зависит от _loaded)
              // рендерится безусловно, СРАЗУ на первом кадре — раньше он
              // был внутри "!_loaded ? спиннер : ListView(...)", и на
              // самый первый кадр после push(), пока PeerProfileCache.get()
              // ещё не резолвился, Hero с этим тегом в дереве попросту не
              // существовал. Flutter же ищет ответный Hero целевого экрана
              // именно на первом кадре пуша — не найдя его, тихо показывает
              // экран без анимации (zoom-out при pop работал, потому что к
              // тому моменту _loaded уже был true). Спиннер теперь только
              // на месте статуса/даты рождения, которые реально зависят от
              // сетевого ответа.
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  Center(
                    child: Hero(
                      tag: 'peer-avatar-${widget.peerAccountId}',
                      child: GestureDetector(
                        onTap: () {
                          final bytes = AvatarCache.peek(widget.peerAccountId);
                          if (bytes != null) showPhotoViewer(context, bytes);
                        },
                        child: CachedAvatarImage(
                          accountId: widget.peerAccountId,
                          radius: 64,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      widget.peerLogin,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (!_loaded)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    if (_profile?.status?.isNotEmpty == true)
                      ListTile(
                        leading: Icon(
                          Icons.chat_bubble_outline,
                          color: AppColors.textMuted,
                        ),
                        title: Text(
                          tr('profile.status'),
                          style: TextStyle(color: AppColors.textPrimary),
                        ),
                        subtitle: Text(
                          _profile!.status!,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    if (_profile?.birthday?.isNotEmpty == true)
                      ListTile(
                        leading: Icon(
                          Icons.cake_outlined,
                          color: AppColors.textMuted,
                        ),
                        title: Text(
                          tr('profile.birthday'),
                          style: TextStyle(color: AppColors.textPrimary),
                        ),
                        subtitle: Text(
                          _profile!.birthday!,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
