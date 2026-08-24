import '../l10n/app_strings.dart';

/// Единые требования к логину — те же самые, что сервер проверяет в
/// register.go (см. auth.ValidateLogin на сервере): 3-32 символа, только
/// латинские буквы и цифры. Среди прочего закрывает обход "зарезервированных"
/// логинов (admin/support/…) через кириллический омоглиф, который на глаз
/// от настоящего латинского не отличить.
final _loginRe = RegExp(r'^[A-Za-z0-9]{3,32}$');

/// Возвращает null, если логин подходит, иначе — готовый к показу текст
/// ошибки.
String? validateLogin(String login) {
  if (!_loginRe.hasMatch(login)) return tr('login.invalid');
  return null;
}
