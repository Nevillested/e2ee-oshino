import 'dart:ui';
import 'package:flutter/material.dart';

/// Единственная нижняя панель, общая для обеих "сторон" HomePlaceholderScreen
/// (список чатов / настройки, см. _buildFlippableBody) — при развороте
/// карточки сама панель не крутится вместе с содержимым, меняется только
/// её иконка (см. вызывающую сторону).
class BottomActionBar extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const BottomActionBar({super.key, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Раньше высота бара была фиксированной, без учёта системных отступов
    // — на gesture-навигации (тонкий инсет) иконка случайно не пересекалась
    // с системной панелью, а на 3-кнопочной навигации Samsung реально
    // пряталась под ней и переставала ловить тапы. Добавляем нижний инсет
    // к общей высоте (просто продлевает блёр под системную панель) и тем
    // же паддингом поднимаем сам ряд с иконкой над ней.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          height: MediaQuery.of(context).size.height / 15 + bottomInset,
          width: double.infinity,
          color: Colors.black.withValues(alpha: 0.12),
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  child: Center(child: Icon(icon, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
