import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_locale.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/frosted_dialog.dart';
import '../widgets/theme_reactive.dart';

// /en/ или /ru/ в зависимости от текущего языка интерфейса (см.
// AppStrings.locale) — обе версии страниц уже развёрнуты на сервере.
String get _termsUrl =>
    'https://ee2e.oshino.space/terms/${AppStrings.locale == AppLocale.ru ? 'ru' : 'en'}/';
String get _privacyUrl =>
    'https://ee2e.oshino.space/privacy/${AppStrings.locale == AppLocale.ru ? 'ru' : 'en'}/';

/// Точка входа из настроек — окно поверх текущего экрана (см. ТЗ
/// пользователя: пункты меню настроек должны открываться "окном", а не
/// отдельным экраном, как раньше через Navigator.push), с тем же
/// полупрозрачным заблюренным стилем, что и у остальных окон настроек (см.
/// FrostedDialog).
Future<void> showAboutWindow(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => FrostedDialog(
      title: Text(
        tr('about.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: const AboutScreen(),
    ),
  );
}

// Раньше здесь были ещё три пункта: "Отзыв" (ручной текст), "Поделиться
// логом" (системный диалог "Отправить через...") и "Очистить лог" — все три
// требовали, чтобы пользователь сам вспомнил зайти сюда и что-то сделать.
// Убраны и объединены в одно: DebugLog.error() + CrashReporter теперь сами,
// без единого диалога, шлют диагностику на сервер при настоящей ошибке (см.
// CrashReporter — троттлинг, только метаданные, никогда содержимое
// сообщений) и сами же чистят лог после успешной отправки.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _version = '${info.version} (${info.buildNumber})');
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Нет приложения, способного открыть ссылку, или запрет от ОС —
      // молча игнорируем, как и _openLink в chat_screen.dart.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(Icons.info_outline, color: AppColors.textMuted),
          title: Text(
            tr('about.version'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            _version ?? '…',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
        ListTile(
          leading: Icon(Icons.description_outlined, color: AppColors.textMuted),
          title: Text(
            tr('about.terms'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => _openUrl(_termsUrl),
        ),
        ListTile(
          leading: Icon(Icons.privacy_tip_outlined, color: AppColors.textMuted),
          title: Text(
            tr('about.privacy'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          onTap: () => _openUrl(_privacyUrl),
        ),
      ],
    );
  }
}
