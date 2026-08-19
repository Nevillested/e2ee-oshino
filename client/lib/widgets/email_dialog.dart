import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/my_email_store.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Простая проверка формата на клиенте — не для безопасности (её всё
/// равно дублирует сервер), просто чтобы не гонять явно мусорные значения
/// по сети и сразу подсветить ошибку.
final _emailFormatRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Точка входа из настроек — НЕ ходит в сеть, читает уже закэшированное
/// значение (см. MyEmailStore, наполняется один раз при входе в
/// аккаунт) и открывает "хаб": если почта уже есть — показываем её как
/// есть (нередактируемо, менять — значит сначала удалить, затем добавить
/// заново с новым подтверждением) с кнопкой удаления; если нет —
/// предлагаем добавить.
Future<void> showEmailDialog(BuildContext context) async {
  final token = await Session.getToken();
  if (token == null) return;
  await showDialog<void>(
    context: context,
    // hostContext — контекст экрана настроек, ОТДЕЛЬНО от контекста
    // самого диалога ниже: диалог мы закрываем (Navigator.pop) ДО того,
    // как запрос на удаление вообще уходит на сервер, и после pop() его
    // собственный context.mounted почти сразу становится false. Раньше
    // именно на нём же (уже закрытом диалоге) и проверялось
    // "context.mounted" перед вызовом updateEmail() — проверка всегда
    // проваливалась, и функция тихо выходила ДО сетевого запроса: почта
    // визуально "удалялась" (диалог закрывался), но по факту не
    // удалялась нигде — ни на сервере, ни в кэше. hostContext (экран
    // настроек) никуда не девается, пока открыты/закрываются дочерние
    // диалоги поверх него — на нём и проверяем.
    builder: (context) => _EmailHubDialog(token: token, hostContext: context),
  );
}

class _EmailHubDialog extends StatelessWidget {
  final String token;
  final BuildContext hostContext;
  const _EmailHubDialog({required this.token, required this.hostContext});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: MyEmailStore.notifier,
      builder: (context, email, _) {
        final hasEmail = email != null && email.isNotEmpty;
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Text(
            tr('email.title'),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          content: Text(
            hasEmail ? email : tr('email.notSet'),
            style: TextStyle(
              color: hasEmail ? AppColors.textPrimary : AppColors.textMuted,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                if (hasEmail) {
                  _showRemoveConfirmDialog(hostContext, token);
                } else {
                  showDialog<void>(
                    context: hostContext,
                    builder: (context) => _AddEmailDialog(token: token),
                  );
                }
              },
              child: Text(
                hasEmail ? tr('email.removeButton') : tr('email.addButton'),
                style: hasEmail ? const TextStyle(color: Colors.red) : null,
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _showRemoveConfirmDialog(
  BuildContext hostContext,
  String token,
) async {
  final confirmed = await showDialog<bool>(
    context: hostContext,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        tr('email.removeConfirmTitle'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: Text(
        tr('email.removeConfirmBody'),
        style: TextStyle(color: AppColors.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            tr('email.removeButton'),
            style: const TextStyle(color: Colors.red),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true || !hostContext.mounted) return;

  try {
    await ApiClient().updateEmail(token, '');
    MyEmailStore.clear();
    if (!hostContext.mounted) return;
    ScaffoldMessenger.of(
      hostContext,
    ).showSnackBar(SnackBar(content: Text(tr('email.removed'))));
  } on ApiException catch (e) {
    if (!hostContext.mounted) return;
    ScaffoldMessenger.of(
      hostContext,
    ).showSnackBar(SnackBar(content: Text(e.message)));
  }
}

enum _Step { enterEmail, enterCode }

class _AddEmailDialog extends StatefulWidget {
  final String token;
  const _AddEmailDialog({required this.token});

  @override
  State<_AddEmailDialog> createState() => _AddEmailDialogState();
}

class _AddEmailDialogState extends State<_AddEmailDialog> {
  final _emailController = TextEditingController();
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

  Future<void> _handleSendCode() async {
    final value = _emailController.text.trim();
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
      MyEmailStore.setEmail(_pendingEmail!);
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
                    ? _handleSendCode
                    : _handleConfirmCode),
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _step == _Step.enterEmail
                      ? tr('email.sendCode')
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
