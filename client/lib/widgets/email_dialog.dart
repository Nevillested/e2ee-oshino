import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Простая проверка формата на клиенте — не для безопасности (её всё
/// равно дублирует сервер), просто чтобы не гонять явно мусорные значения
/// по сети и сразу подсветить ошибку.
final _emailFormatRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

Future<void> showEmailDialog(BuildContext context) async {
  final token = await Session.getToken();
  if (token == null) return;
  final info = await ApiClient().getMyAccountInfo(token);
  if (!context.mounted) return;

  final result = await showDialog<String>(
    context: context,
    builder: (context) => _EmailDialog(initial: info?.email ?? ''),
  );
  if (result == null) return;

  try {
    await ApiClient().updateEmail(token, result);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('email.saved'))));
  } on ApiException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(e.message)));
  }
}

class _EmailDialog extends StatefulWidget {
  final String initial;
  const _EmailDialog({required this.initial});

  @override
  State<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends State<_EmailDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isNotEmpty && !_emailFormatRe.hasMatch(value)) {
      setState(() => _error = tr('email.invalid'));
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        tr('email.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('email.description'),
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.emailAddress,
            style: TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: tr('email.hint'),
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        TextButton(onPressed: _save, child: Text(tr('common.save'))),
      ],
    );
  }
}
