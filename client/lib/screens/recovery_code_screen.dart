import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/theme_reactive.dart';
import 'set_new_password_screen.dart';

/// Второй шаг — код из письма. Проверяется отдельным вызовом (не расходуя
/// код), реальная смена пароля — на следующем экране: если пользователь
/// там передумает/ошибётся в новом пароле, код всё ещё будет действителен
/// для повторной попытки, не придётся запрашивать заново.
class RecoveryCodeScreen extends StatefulWidget {
  final String login;

  const RecoveryCodeScreen({super.key, required this.login});

  @override
  State<RecoveryCodeScreen> createState() => _RecoveryCodeScreenState();
}

class _RecoveryCodeScreenState extends State<RecoveryCodeScreen> {
  final _codeController = TextEditingController();
  final _apiClient = ApiClient();

  bool _isLoading = false;
  String? _errorText;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleVerify() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await _apiClient.verifyRecoveryCode(widget.login, code);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              SetNewPasswordScreen(login: widget.login, token: code),
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
      appBar: AppBar(title: Text(tr('recovery.codeTitle'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthTextField(
                controller: _codeController,
                hintText: tr('recovery.codeHint'),
                keyboardType: TextInputType.visiblePassword,
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
                    : Text(tr('recovery.confirmCode')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
