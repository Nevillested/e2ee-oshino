import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

const _supportEmail = 'support@oshino.space';

/// Показывается, если у пользователя нет почты, привязанной к аккаунту —
/// автоматическое восстановление в этом случае невозможно (не на что
/// слать код), единственный путь — списаться с поддержкой напрямую и
/// подтвердить личность вручную (см. cmd/admin на сервере — там же
/// решается сам сброс пароля/TOTP после разговора).
class RecoveryNoEmailScreen extends StatelessWidget {
  const RecoveryNoEmailScreen({super.key});

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
                tr('recovery.noEmailBody'),
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
