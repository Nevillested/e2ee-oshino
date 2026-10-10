import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Полупрозрачная заблюренная замена AlertDialog — единый стиль для ВСЕХ
/// всплывающих окон настроек (см. ТЗ пользователя: каждый пункт меню
/// настроек должен открываться "окном поверх" текущего экрана, а не
/// отдельным экраном, и это окно должно иметь тот же эффект блюра, что и
/// многие кнопки в чате — см. BottomActionBar/message_context_menu: тот же
/// приём, ClipRRect + BackdropFilter + AppColors.surface с альфой).
/// Параметры (title/content/actions) намеренно повторяют форму AlertDialog
/// — прямая замена везде, где он использовался.
class FrostedDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;

  const FrostedDialog({super.key, this.title, this.content, this.actions});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.textMuted.withValues(alpha: 0.18),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            // Material(color: transparent) — то же лечение, что уже
            // применено к ListTile в списке чатов (см. home_placeholder_
            // screen.dart): Dialog изнутри задаёт Material с прозрачным
            // фоном, а ListTile/SwitchListTile (Privacy/App Lock/About —
            // теперь встроены в это окно вместо отдельного экрана) ищут
            // ближайший Material именно для собственной заливки/ripple —
            // без этой обёртки Flutter честно предупреждает в консоль, что
            // они могут оказаться невидимыми.
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DefaultTextStyle(
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        child: title!,
                      ),
                    ),
                  if (content != null)
                    Flexible(child: SingleChildScrollView(child: content!)),
                  if (actions != null && actions!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: actions!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
