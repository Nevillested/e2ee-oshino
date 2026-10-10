import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_loading_indicator.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';
import 'login_screen.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class VerifyTotpScreen extends StatefulWidget {
  final String login;
  final String totpUrl;

  const VerifyTotpScreen({
    super.key,
    required this.login,
    required this.totpUrl,
  });

  @override
  State<VerifyTotpScreen> createState() => _VerifyTotpScreenState();
}

class _VerifyTotpScreenState extends State<VerifyTotpScreen> {
  final _codeController = TextEditingController();
  final _apiClient = ApiClient();

  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  String _extractSecret(String otpauthUrl) {
    final uri = Uri.parse(otpauthUrl);
    return uri.queryParameters['secret'] ?? '';
  }

  Future<void> _handleVerify() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await _apiClient.verifyTotp(widget.login, _codeController.text.trim());

      if (!mounted) return;
      // Убираем из стека и экран регистрации, и экран подтверждения —
      // пользователь должен попасть на LoginScreen и оттуда уже
      // залогиниться с работающим TOTP-кодом.
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
      appBar: AppBar(title: Text(tr('totp.title'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('totp.scanInstruction'),
                style: TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: 20),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: QrImageView(
                    data: widget.totpUrl,
                    version: QrVersions.auto,
                    size: 200,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                tr('totp.manualEntry'),
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _extractSecret(widget.totpUrl),
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.copy, color: AppColors.primary),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _extractSecret(widget.totpUrl)),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr('totp.codeCopied'))),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              AuthTextField(
                controller: _codeController,
                hintText: tr('auth.totpHint'),
                keyboardType: TextInputType.number,
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 14),
                Text(_errorText!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleVerify,
                child: _isLoading
                    ? const AppLoadingIndicator(size: 22, color: Colors.white)
                    : Text(tr('totp.confirm')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
