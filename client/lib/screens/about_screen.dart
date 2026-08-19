import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../widgets/theme_reactive.dart';

const _termsUrl = 'https://ee2e.oshino.space/terms';
const _privacyUrl = 'https://ee2e.oshino.space/privacy';

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
    return Scaffold(
      appBar: AppBar(title: Text(tr('about.title'))),
      body: ListView(
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
            leading: Icon(
              Icons.description_outlined,
              color: AppColors.textMuted,
            ),
            title: Text(
              tr('about.terms'),
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () => _openUrl(_termsUrl),
          ),
          ListTile(
            leading: Icon(
              Icons.privacy_tip_outlined,
              color: AppColors.textMuted,
            ),
            title: Text(
              tr('about.privacy'),
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () => _openUrl(_privacyUrl),
          ),
          ListTile(
            leading: Icon(Icons.feedback_outlined, color: AppColors.textMuted),
            title: Text(
              tr('about.feedback'),
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => const _FeedbackDialog(),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog();

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = tr('about.feedbackEmpty'));
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });
    final token = await Session.getToken();
    if (token == null) return;
    try {
      await ApiClient().sendFeedback(token, text);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('about.feedbackSent'))));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        tr('about.feedback'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: TextField(
        controller: _controller,
        maxLines: 5,
        style: TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: tr('about.feedbackHint'),
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: _isLoading ? null : _handleSend,
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('common.send')),
        ),
      ],
    );
  }
}
