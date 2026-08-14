import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../utils/password_validator.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';

/// Смена пароля внутри уже открытого аккаунта (настройки) — только новый
/// пароль и его подтверждение, старый пароль не спрашиваем: раз
/// пользователь уже вошёл (валидный токен сессии), личность уже
/// подтверждена самим фактом входа.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
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
    final policyError = validatePassword(password);
    if (policyError != null) {
      setState(() => _errorText = policyError);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final token = await Session.getToken();
      if (token == null) return;
      await _apiClient.changePassword(token, password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('changePassword.success'))),
      );
      Navigator.pop(context);
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
      appBar: AppBar(title: Text(tr('changePassword.title'))),
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
              const SizedBox(height: 6),
              Text(
                tr('password.requirementsHint'),
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
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
