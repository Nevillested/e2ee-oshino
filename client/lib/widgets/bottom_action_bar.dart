import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Высота, которую нужно резервировать СНИЗУ прокручиваемого контента под
/// плавающую капсулу (см. BottomActionBar ниже) — единая формула, чтобы
/// её не размножать по каждому табу (Чаты/Настройки/Профиль) отдельно.
/// Сама панель — Positioned ПОВЕРХ контента, а не сосед в Column: величина
/// отступа та же самая, что была снаружи (см. историю правки), меняется
/// только то, ЧТО именно им ограничено — раньше отступ резал сам
/// прокручиваемый viewport (последний чат физически не мог доехать до
/// этой зоны, ни при каком скролле), теперь это внутренний паддинг
/// прокрутки — тот же зазор в покое, но последний элемент можно
/// докрутить под капсулу и увидеть его сквозь блюр (см. ТЗ пользователя).
double bottomActionBarReservedHeight(BuildContext context) =>
    60.0 + MediaQuery.of(context).padding.bottom + 14;

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
    // Фиксированная ширина кнопки — 1/5 ширины экрана (см. ТЗ пользователя):
    // с запасом хватает под любую подпись при любом масштабе шрифта из
    // настроек (TextPainter-измерение ширины текста раньше не учитывало
    // пользовательский textScaler из настроек, из-за чего подпись при
    // увеличенном масштабе шрифта переносилась на вторую строку).
    final buttonSize = MediaQuery.of(context).size.width / 5;
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
                  for (var i = 0; i < items.length; i++)
                    _buildItem(i, buttonSize),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(int i, double buttonSize) {
    final item = items[i];
    final selected = i == selectedIndex;
    final color = selected ? AppColors.primary : AppColors.textPrimary;

    // И фото, и заглушка — ровно 20px, вплотную к размеру обычных иконок
    // (Icon(size: 20) у "Чаты"/"Настройки") — раньше кружок был 30px
    // (radius: 15) при иконке-человечке всего 15px внутри него, из-за
    // этой рассинхронизации высот именно капсула профиля получалась
    // выше и потому визуально крупнее остальных (ширина у всех и так
    // одинаковая, см. buttonSize), а сама заглушка внутри — мельче.
    const leadingSize = 20.0;
    final Widget leading;
    if (item.avatar != null) {
      leading = ValueListenableBuilder<Uint8List?>(
        valueListenable: item.avatar!,
        builder: (context, bytes, _) => bytes != null
            ? CircleAvatar(
                radius: leadingSize / 2,
                backgroundImage: MemoryImage(bytes),
              )
            : Icon(Icons.person_outline, size: leadingSize, color: color),
      );
    } else {
      leading = Icon(item.icon, size: leadingSize, color: color);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onTabSelected(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 4),
        width: buttonSize,
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
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
