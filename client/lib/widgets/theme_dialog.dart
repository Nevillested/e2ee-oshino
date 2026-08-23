import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../storage/theme_store.dart';
import '../theme/app_theme.dart';
import 'frosted_dialog.dart';
import 'theme_toggle_switch.dart';

Future<void> showThemeDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (context) => const _ThemeDialog(),
  );
}

class _ThemeDialog extends StatefulWidget {
  const _ThemeDialog();

  @override
  State<_ThemeDialog> createState() => _ThemeDialogState();
}

class _ThemeDialogState extends State<_ThemeDialog> {
  late AppThemeMode _mode = AppColors.mode;

  void _toggle(bool isLight) {
    final mode = isLight ? AppThemeMode.light : AppThemeMode.dark;
    setState(() => _mode = mode);
    // Применяем сразу, а не по кнопке "Сохранить" — переключатель ЖИВОЙ,
    // пользователь должен видеть результат немедленно, кнопка внизу тут
    // только чтобы закрыть окно.
    ThemeStore.setMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    final isLight = _mode == AppThemeMode.light;
    return FrostedDialog(
      title: Text(
        tr('theme.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemeToggleSwitch(isOn: isLight, onChanged: _toggle),
          const SizedBox(height: 16),
          Text(
            isLight ? tr('theme.light') : tr('theme.dark'),
            style: TextStyle(color: AppColors.textPrimary, fontSize: 15),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.done')),
        ),
      ],
    );
  }
}
