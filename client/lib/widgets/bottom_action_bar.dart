import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'avatar_settings_tile.dart';

class BottomTabItem {
  final IconData? icon;
  final String label;
  // Для таба "Профиль" — вместо статичной иконки живое мини-фото профиля
  // (см. MyAvatarStore.notifier), обновляется само по мере смены фото.
  final ValueListenable<Uint8List?>? avatar;

  const BottomTabItem({this.icon, required this.label, this.avatar})
    : assert(icon != null || avatar != null);
}

/// Нижняя панель на N табов (сейчас — 3: чаты/настройки/профиль, см.
/// HomePlaceholderScreen._buildFlippableBody) — плавающая овальная капсула
/// по образцу референса пользователя: ширина по содержимому (не на весь
/// экран), отцентрирована, у выбранного таба — анимированная овальная
/// подсветка позади иконки+подписи.
class BottomActionBar extends StatelessWidget {
  final List<BottomTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  const BottomActionBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    // Тот же системный нижний отступ, что раньше держал панель над
    // 3-кнопочной навигацией Samsung — теперь просто зазор под плавающей
    // капсулой вместо паддинга внутри бывшего полноширинного бара.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset + 14),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppColors.textMuted.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++) _buildItem(i),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(int i) {
    final item = items[i];
    final selected = i == selectedIndex;
    final color = selected ? AppColors.primary : AppColors.textPrimary;

    final Widget leading;
    if (item.avatar != null) {
      leading = ValueListenableBuilder<Uint8List?>(
        valueListenable: item.avatar!,
        builder: (context, bytes, _) => AvatarThumbnail(
          bytes: bytes,
          radius: 15,
          placeholderColor: color,
          placeholderBackground: Colors.transparent,
        ),
      );
    } else {
      leading = Icon(item.icon, size: 20, color: color);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onTabSelected(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(height: 2),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
