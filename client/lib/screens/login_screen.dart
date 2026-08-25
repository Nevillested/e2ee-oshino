import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_locale.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../storage/locale_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';
import 'home_placeholder_screen.dart';
import '../device_setup.dart';
import '../widgets/loading_overlay.dart';
import 'recovery_choose_method_screen.dart';
import 'recovery_purpose.dart';

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
    showLoadingOverlay(context, tr('auth.loggingIn'));

    try {
      final result = await _apiClient.login(
        _loginController.text.trim(),
        _passwordController.text,
        _totpController.text.trim(),
      );
      final token = result.token;

      await Session.saveToken(token);
      await Session.saveLogin(_loginController.text.trim());
      // Язык, сохранённый на сервере, — источник истины при входе, даже
      // если на этом устройстве до этого стоял другой (например, только
      // что переустановили приложение).
      await LocaleStore.setLocale(
        result.language == 'ru' ? AppLocale.ru : AppLocale.en,
      );
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
    return ThemeReactive(builder: (context) => _build(context));
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('login.title'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthTextField(
                controller: _loginController,
                hintText: tr('auth.loginHint'),
              ),
              const SizedBox(height: 14),
              AuthTextField(
                controller: _passwordController,
                hintText: tr('auth.passwordHint'),
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
                hintText: tr('auth.totpHint'),
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
                    ? const AppLoadingIndicator(size: 22, color: Colors.white)
                    : Text(tr('welcome.login')),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _isLoading
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                const RecoveryChooseMethodScreen(
                                  purpose: RecoveryPurpose.password,
                                ),
                          ),
                        );
                      },
                child: Text(tr('recovery.forgotPassword')),
              ),
              TextButton(
                onPressed: _isLoading
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                const RecoveryChooseMethodScreen(
                                  purpose: RecoveryPurpose.totp,
                                ),
                          ),
                        );
                      },
                child: Text(tr('recovery.forgotTotp')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
