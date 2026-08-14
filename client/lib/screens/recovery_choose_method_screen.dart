import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import 'forgot_password_screen.dart';
import 'recovery_no_email_screen.dart';

/// Первый экран восстановления пароля — развилка на два разных пути,
/// смотря указывал ли пользователь почту в настройках заранее:
/// "указывал" ведёт к обычному флоу код-по-почте (ForgotPasswordScreen),
/// "не указывал" — к инструкции написать напрямую в поддержку (у нас нет
/// автоматического способа подтвердить личность без почты в базе).
class RecoveryChooseMethodScreen extends StatelessWidget {
  const RecoveryChooseMethodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('recovery.chooseTitle'))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ForgotPasswordScreen(),
                    ),
                  );
                },
                child: Text(tr('recovery.hasEmailButton')),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RecoveryNoEmailScreen(),
                    ),
                  );
                },
                child: Text(tr('recovery.noEmailButton')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
