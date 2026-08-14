import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Простая проверка формата на клиенте — не для безопасности (её всё
/// равно дублирует сервер), просто чтобы не гонять явно мусорные значения
/// по сети и сразу подсветить ошибку.
final _emailFormatRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Установка НОВОЙ почты требует подтверждения владения (код на неё же) —
/// поэтому диалог двухшаговый: ввод адреса → код из письма. Снятие уже
/// сохранённой почты (пустое поле) подтверждения не требует, это делается
/// сразу. Весь сетевой обмен и закрытие диалога — внутри самого виджета,
/// вызывающей стороне (settings_screen.dart) достаточно просто открыть его.
Future<void> showEmailDialog(BuildContext context) async {
  final token = await Session.getToken();
  if (token == null) return;
  final info = await ApiClient().getMyAccountInfo(token);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => _EmailDialog(initial: info?.email ?? '', token: token),
  );
}

enum _Step { enterEmail, enterCode }

class _EmailDialog extends StatefulWidget {
  final String initial;
  final String token;
  const _EmailDialog({required this.initial, required this.token});

  @override
  State<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends State<_EmailDialog> {
  late final _emailController = TextEditingController(text: widget.initial);
  final _codeController = TextEditingController();
  final _apiClient = ApiClient();

  _Step _step = _Step.enterEmail;
  String? _pendingEmail;
  String? _error;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handlePrimaryAction() async {
    final value = _emailController.text.trim();

    if (value.isEmpty) {
      // Пустое поле — просто снять уже сохранённую почту, без кода.
      setState(() {
        _isLoading = true;
        _error = null;
      });
      try {
        await _apiClient.updateEmail(widget.token, '');
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('email.removed'))));
      } on ApiException catch (e) {
        setState(() => _error = e.message);
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
      return;
    }

    if (!_emailFormatRe.hasMatch(value)) {
      setState(() => _error = tr('email.invalid'));
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await _apiClient.requestEmailVerification(widget.token, value);
      if (!mounted) return;
      setState(() {
        _pendingEmail = value;
        _step = _Step.enterCode;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleConfirmCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await _apiClient.confirmEmailVerification(widget.token, code);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('email.saved'))));
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
        _step == _Step.enterEmail
            ? tr('email.title')
            : tr('recovery.codeTitle'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _step == _Step.enterEmail
            ? _buildEmailStep()
            : _buildCodeStep(),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: _isLoading
              ? null
              : (_step == _Step.enterEmail
                    ? _handlePrimaryAction
                    : _handleConfirmCode),
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _step == _Step.enterEmail
                      ? (_emailController.text.trim().isEmpty
                            ? tr('email.removeButton')
                            : tr('email.sendCode'))
                      : tr('recovery.confirmCode'),
                ),
        ),
      ],
    );
  }

  List<Widget> _buildEmailStep() {
    return [
      Text(
        tr('email.description'),
        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        style: TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: tr('email.hint'),
          errorText: _error,
        ),
        onChanged: (_) {
          setState(() => _error = null);
        },
      ),
    ];
  }

  List<Widget> _buildCodeStep() {
    return [
      Text(
        '${tr('email.codeSentTo')} $_pendingEmail',
        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _codeController,
        style: TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: tr('recovery.codeHint'),
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
    ];
  }
}
