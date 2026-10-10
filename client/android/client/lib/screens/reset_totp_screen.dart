import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/theme_reactive.dart';
import 'verify_totp_screen.dart';

/// Финальный шаг восстановления доступа к аутентификатору (ветка
/// RecoveryPurpose.totp) — зеркало SetNewPasswordScreen у пароля, только
/// вместо формы ввода нового значения тут генерировать нечего вводить:
/// новый TOTP-секрет сервер создаёт сам (см. /account/recover/reset-totp,
/// тот же одноразовый расход кода, что и у смены пароля). Как только
/// секрет получен, дальше — ТОТ ЖЕ ЭКРАН подтверждения, что при
/// регистрации (VerifyTotpScreen, QR + ручной ввод + текущий код) — не
/// дублируем его разметку заново.
class ResetTotpScreen extends StatefulWidget {
  final String login;
  final String token;

  const ResetTotpScreen({super.key, required this.login, required this.token});

  @override
  State<ResetTotpScreen> createState() => _ResetTotpScreenState();
}

class _ResetTotpScreenState extends State<ResetTotpScreen> {
  final _apiClient = ApiClient();
  String? _totpUrl;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() => _errorText = null);
    try {
      final url = await _apiClient.resetTotpWithRecoveryCode(
        widget.login,
        widget.token,
      );
      if (!mounted) return;
      setState(() => _totpUrl = url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_totpUrl != null) {
      return VerifyTotpScreen(login: widget.login, totpUrl: _totpUrl!);
    }
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('recovery.titleTotp'))),
      body: SafeArea(
        child: Center(
          child: _errorText == null
              ? const AppLoadingIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _errorText!,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _generate,
                        child: Text(tr('common.retry')),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
