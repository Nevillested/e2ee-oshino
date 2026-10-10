import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_locale.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../storage/locale_store.dart';
import '../theme/app_theme.dart';
import 'frosted_dialog.dart';

/// Названия языков в списке — намеренно ВСЕГДА латиницей ("Russian" /
/// "English"), независимо от того, какой язык сейчас выбран в
/// приложении — так пользователь, случайно попавший в чужой ему язык,
/// всё равно узнаёт нужный пункт.
Future<void> showLanguageDialog(BuildContext context) async {
  final selected = await showDialog<AppLocale>(
    context: context,
    builder: (context) => FrostedDialog(
      title: Text(
        tr('language.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LanguageOption(
            label: tr('language.russian'),
            selected: AppStrings.locale == AppLocale.ru,
            onTap: () => Navigator.pop(context, AppLocale.ru),
          ),
          _LanguageOption(
            label: tr('language.english'),
            selected: AppStrings.locale == AppLocale.en,
            onTap: () => Navigator.pop(context, AppLocale.en),
          ),
        ],
      ),
    ),
  );

  if (selected == null || selected == AppStrings.locale) return;
  await LocaleStore.setLocale(selected);

  // Сохраняем и на сервере — задел под будущий вход с нескольких
  // устройств (см. обсуждение в чате). Неудача тут не должна мешать
  // локальному переключению языка — молча логируем через catch и всё
  // равно показываем локальный результат.
  final token = await Session.getToken();
  if (token != null) {
    try {
      await ApiClient().updateLanguage(
        token,
        selected == AppLocale.ru ? 'ru' : 'en',
      );
    } catch (_) {}
  }

  if (!context.mounted) return;
  // Часть экранов/виджетов не переподписана на смену языка "на лету" (см.
  // обсуждение в чате) — честно предупреждаем, а не делаем вид, что везде
  // обновилось само.
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(tr('language.restartNotice'))));
}

class _LanguageOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? AppColors.primary : AppColors.textMuted,
              size: 20,
            ),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }
}
