import '../l10n/app_strings.dart';

/// Единые требования к паролю — те же самые, что сервер проверяет в
/// register.go/password_recovery.go/change_password.go (см.
/// auth.ValidatePassword на сервере): минимум 6 символов, заглавная и
/// строчная буква, цифра, спецсимвол. Порядок проверок тоже совпадает с
/// серверным, чтобы сообщение об ошибке было предсказуемым.
///
/// Возвращает null, если пароль подходит, иначе — готовый к показу текст
/// ошибки (что именно не так).
String? validatePassword(String password) {
  if (password.length < 6) return tr('password.tooShort');
  if (!password.contains(RegExp(r'[A-Z]'))) return tr('password.needUpper');
  if (!password.contains(RegExp(r'[a-z]'))) return tr('password.needLower');
  if (!password.contains(RegExp(r'[0-9]'))) return tr('password.needDigit');
  if (!password.contains(RegExp(r'[^A-Za-z0-9]'))) {
    return tr('password.needSpecial');
  }
  return null;
}
