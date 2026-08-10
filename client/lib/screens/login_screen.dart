import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_text_field.dart';
import 'home_placeholder_screen.dart';
import '../device_setup.dart';
import '../widgets/loading_overlay.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  final _totpController = TextEditingController();
  final _apiClient = ApiClient();

  bool _passwordHidden = true;
  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    _totpController.dispose();
    super.dispose();
  }

Future<void> _handleLogin() async {
  FocusScope.of(context).unfocus();
  setState(() {
      _isLoading = true;
      _errorText = null;
    });
showLoadingOverlay(context, 'Идёт авторизация, подождите');

    try {
      final token = await _apiClient.login(
        _loginController.text.trim(),
        _passwordController.text,
        _totpController.text.trim(),
      );

      await Session.saveToken(token);
      await Session.saveLogin(_loginController.text.trim());
      await ensureDeviceRegistered(_apiClient, token);

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
  context,
  MaterialPageRoute(builder: (context) => const HomePlaceholderScreen()),
  (route) => false,
);
    } catch (e) {
      setState(() {
        _errorText = e.toString();
      });
    } finally {
  hideLoadingOverlay();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Вход')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthTextField(
                controller: _loginController,
                hintText: 'Логин',
              ),
              const SizedBox(height: 14),
              AuthTextField(
                controller: _passwordController,
                hintText: 'Пароль',
                obscureText: _passwordHidden,
                suffixIcon: IconButton(
                  icon: Icon(
                    _passwordHidden ? Icons.visibility_off : Icons.visibility,
                    color: AppColors.textMuted,
                  ),
                  onPressed: () {
                    setState(() {
                      _passwordHidden = !_passwordHidden;
                    });
                  },
                ),
              ),
              const SizedBox(height: 14),
              AuthTextField(
                controller: _totpController,
                hintText: 'Код из аутентификатора',
                keyboardType: TextInputType.number,
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 14),
                Text(_errorText!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleLogin,
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Войти'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
