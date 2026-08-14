import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';
import 'login_screen.dart';

/// Финальный шаг восстановления — новый пароль. token здесь — тот же код
/// из письма (см. RecoveryCodeScreen): сервер на /account/recover/reset
/// перепроверяет его заново и расходует одноразово при успехе.
class SetNewPasswordScreen extends StatefulWidget {
  final String login;
  final String token;

  const SetNewPasswordScreen({
    super.key,
    required this.login,
    required this.token,
  });

  @override
  State<SetNewPasswordScreen> createState() => _SetNewPasswordScreenState();
}

class _SetNewPasswordScreenState extends State<SetNewPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _apiClient = ApiClient();

  bool _passwordHidden = true;
  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final password = _passwordController.text;
    if (password != _confirmController.text) {
      setState(() => _errorText = tr('recovery.passwordsDontMatch'));
      return;
    }
    if (password.trim().length < 6) {
      setState(() => _errorText = tr('recovery.passwordTooShort'));
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await _apiClient.resetPasswordWithRecoveryCode(
        widget.login,
        widget.token,
        password,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('recovery.success'))),
      );
      // Убираем со стека весь путь восстановления (логин → код → этот
      // экран) — назад из LoginScreen должно попадать сразу на самый
      // первый экран (регистрация/вход), как и обычно.
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => route.isFirst,
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
      appBar: AppBar(title: Text(tr('recovery.newPasswordTitle'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthTextField(
                controller: _passwordController,
                hintText: tr('recovery.newPasswordHint'),
                obscureText: _passwordHidden,
                suffixIcon: IconButton(
                  icon: Icon(
                    _passwordHidden ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() => _passwordHidden = !_passwordHidden);
                  },
                ),
              ),
              const SizedBox(height: 14),
              AuthTextField(
                controller: _confirmController,
                hintText: tr('recovery.confirmPasswordHint'),
                obscureText: _passwordHidden,
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 14),
                Text(_errorText!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleSave,
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(tr('recovery.save')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
