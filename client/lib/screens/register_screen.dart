import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_text_field.dart';
import 'verify_totp_screen.dart';
import '../widgets/loading_overlay.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  final _apiClient = ApiClient();

  bool _passwordHidden = true;
  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

Future<void> _handleRegister() async {
  FocusScope.of(context).unfocus();
  setState(() {
  _isLoading = true;
  _errorText = null;
});
showLoadingOverlay(context, 'Идёт регистрация, подождите');

try {
      final totpUrl = await _apiClient.register(
        _loginController.text.trim(),
        _passwordController.text,
      );

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VerifyTotpScreen(
            login: _loginController.text.trim(),
            totpUrl: totpUrl,
          ),
        ),
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
      appBar: AppBar(title: const Text('Регистрация')),
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
              if (_errorText != null) ...[
                const SizedBox(height: 14),
                Text(_errorText!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleRegister,
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Далее'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
