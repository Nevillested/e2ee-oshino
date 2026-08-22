import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'recovery_purpose.dart';

const _supportEmail = 'support@oshino.space';

/// Показывается, если у пользователя нет почты, привязанной к аккаунту —
/// автоматическое восстановление в этом случае невозможно (не на что
/// слать код), единственный путь — списаться с поддержкой напрямую и
/// подтвердить личность вручную (см. cmd/admin на сервере — там же
/// решается сам сброс пароля/TOTP после разговора). Общий для обоих
/// purpose — только тема письма в тексте разная.
class RecoveryNoEmailScreen extends StatelessWidget {
  final RecoveryPurpose purpose;

  const RecoveryNoEmailScreen({super.key, required this.purpose});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('recovery.noEmailTitle'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                purpose == RecoveryPurpose.password
                    ? tr('recovery.noEmailBody')
                    : tr('recovery.noEmailBodyTotp'),
                style: TextStyle(color: AppColors.textPrimary, height: 1.4),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(tr('recovery.copyEmail')),
                onPressed: () {
                  Clipboard.setData(const ClipboardData(text: _supportEmail));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(tr('common.copied'))),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
