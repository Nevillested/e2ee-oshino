import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import 'forgot_password_screen.dart';
import 'recovery_no_email_screen.dart';
import 'recovery_purpose.dart';

/// Первый экран восстановления — развилка на два разных пути, смотря
/// указывал ли пользователь почту в настройках заранее: "указывал" ведёт
/// к обычному флоу код-по-почте (ForgotPasswordScreen), "не указывал" — к
/// инструкции написать напрямую в поддержку (у нас нет автоматического
/// способа подтвердить личность без почты в базе).
///
/// [purpose] — что именно восстанавливаем (пароль или доступ к
/// аутентификатору, см. RecoveryPurpose) — тот же самый флоу для обоих
/// случаев (сервер и так не завязан на цель, см. checkRecoveryToken на
/// бэкенде), различаются только надписи на экранах и то, что происходит
/// на последнем шаге.
class RecoveryChooseMethodScreen extends StatelessWidget {
  final RecoveryPurpose purpose;

  const RecoveryChooseMethodScreen({super.key, required this.purpose});

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
                      builder: (context) =>
                          ForgotPasswordScreen(purpose: purpose),
                    ),
                  );
                },
                child: Text(
                  purpose == RecoveryPurpose.password
                      ? tr('recovery.hasEmailButton')
                      : tr('recovery.hasEmailButtonTotp'),
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          RecoveryNoEmailScreen(purpose: purpose),
                    ),
                  );
                },
                child: Text(
                  purpose == RecoveryPurpose.password
                      ? tr('recovery.noEmailButton')
                      : tr('recovery.noEmailButtonTotp'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
