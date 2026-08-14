import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';
import 'recovery_code_screen.dart';

/// Первый шаг восстановления пароля — ввод логина. Сервер всегда отвечает
/// одинаково независимо от того, нашёлся аккаунт и указана ли у него почта
/// (см. NewRecoverRequestHandler на сервере) — поэтому здесь нет отдельной
/// ветки "логин не найден", всегда просто переходим дальше с одинаковым
/// информационным текстом.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

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
          builder: (context) => RecoveryCodeScreen(login: login),
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
      appBar: AppBar(title: Text(tr('recovery.title'))),
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
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(tr('recovery.sendCode')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
