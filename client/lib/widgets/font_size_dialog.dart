import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../storage/text_scale_store.dart';
import '../theme/app_theme.dart';

Future<void> showFontSizeDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (context) => const _FontSizeDialog(),
  );
}

class _FontSizeDialog extends StatefulWidget {
  const _FontSizeDialog();

  @override
  State<_FontSizeDialog> createState() => _FontSizeDialogState();
}

class _FontSizeDialogState extends State<_FontSizeDialog> {
  late double _scale = TextScaleStore.notifier.value;

  void _onChanged(double value) {
    final steps = TextScaleStore.steps;
    final index = value.round().clamp(0, steps.length - 1);
    final scale = steps[index];
    setState(() => _scale = scale);
    // Применяем сразу, как и ThemeStore/LocaleStore — пользователь должен
    // видеть результат немедленно, кнопка внизу тут только чтобы закрыть.
    TextScaleStore.setScale(scale);
  }

  @override
  Widget build(BuildContext context) {
    final steps = TextScaleStore.steps;
    final index = steps.indexOf(_scale).clamp(0, steps.length - 1);
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        tr('fontSize.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              tr('fontSize.preview'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15 * _scale,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Slider(
            value: index.toDouble(),
            min: 0,
            max: (steps.length - 1).toDouble(),
            divisions: steps.length - 1,
            activeColor: AppColors.primary,
            onChanged: _onChanged,
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
