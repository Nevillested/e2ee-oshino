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
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          height: MediaQuery.of(context).size.height / 15,
          width: double.infinity,
          color: Colors.black.withValues(alpha: 0.12),
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
