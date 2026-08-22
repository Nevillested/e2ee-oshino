import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class BottomTabItem {
  final IconData icon;
  final String label;
  const BottomTabItem({required this.icon, required this.label});
}

/// Нижняя панель на N табов (сейчас — 3: чаты/настройки/профиль, см.
/// HomePlaceholderScreen._buildFlippableBody) — раньше была
/// однокнопочным переключателем "туда-обратно" (чаты⇄настройки), теперь
/// настоящий таб-бар с подсветкой текущего раздела.
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
    // Раньше высота бара была фиксированной, без учёта системных отступов
    // — на gesture-навигации (тонкий инсет) иконка случайно не пересекалась
    // с системной панелью, а на 3-кнопочной навигации Samsung реально
    // пряталась под ней и переставала ловить тапы. Добавляем нижний инсет
    // к общей высоте (просто продлевает блёр под системную панель) и тем
    // же паддингом поднимаем сам ряд с иконками над ней.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          height: MediaQuery.of(context).size.height / 15 + bottomInset + 14,
          width: double.infinity,
          color: Colors.black.withValues(alpha: 0.12),
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onTabSelected(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          items[i].icon,
                          color: i == selectedIndex
                              ? AppColors.primary
                              : Colors.white,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: i == selectedIndex
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: i == selectedIndex
                                ? AppColors.primary
                                : Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
