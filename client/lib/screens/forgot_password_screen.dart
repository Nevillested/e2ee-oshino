import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';
import 'recovery_code_screen.dart';
import 'recovery_purpose.dart';

/// Шаг восстановления (ветка "почта указывалась") — ввод логина. Общий
/// для обоих purpose (пароль/аутентификатор) — сервер отдельно сообщает
/// и "такого логина нет", и "у аккаунта не указана почта" (см.
/// NewRecoverRequestHandler, он тоже не завязан на цель) — ApiClient
/// превращает это в понятный текст ошибки, ловим его ниже как обычно.
class ForgotPasswordScreen extends StatefulWidget {
  final RecoveryPurpose purpose;

  const ForgotPasswordScreen({super.key, required this.purpose});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _loginController = TextEditingController();
  final _apiClient = ApiClient();

  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _loginController.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final login = _loginController.text.trim();
    if (login.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await _apiClient.requestPasswordRecovery(login);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              RecoveryCodeScreen(login: login, purpose: widget.purpose),
        ),
      );
    } catch (e) {
      setState(() {
        _errorText = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.purpose == RecoveryPurpose.password
              ? tr('recovery.title')
              : tr('recovery.titleTotp'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('recovery.requestSentInfo'),
                style: TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: 20),
              AuthTextField(
                controller: _loginController,
                hintText: tr('auth.loginHint'),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 14),
                Text(_errorText!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleSend,
                child: _isLoading
                    ? const AppLoadingIndicator(size: 22, color: Colors.white)
                    : Text(tr('recovery.sendCode')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
