import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_text_field.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Подтверждение')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Отсканируй эту ссылку в приложении-аутентификаторе '
                '(Google Authenticator, Aegis и т.п.), затем введи текущий код:',
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
  'Или введи секретный код вручную:',
  style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
),
const SizedBox(height: 8),
Row(
  children: [
    Expanded(
      child: SelectableText(
        _extractSecret(widget.totpUrl),
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          letterSpacing: 1.5,
        ),
      ),
    ),
    IconButton(
      icon: const Icon(Icons.copy, color: AppColors.primary),
      onPressed: () {
        Clipboard.setData(
          ClipboardData(text: _extractSecret(widget.totpUrl)),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Код скопирован')),
        );
      },
    ),
  ],
),
const SizedBox(height: 24),
              AuthTextField(
                controller: _codeController,
                hintText: 'Код из аутентификатора',
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
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Подтвердить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
