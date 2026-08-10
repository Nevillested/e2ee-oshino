import 'package:shared_preferences/shared_preferences.dart';
import 'api/api_client.dart';

/// Обёртка над локальным хранилищем ключ-значение на устройстве.
/// Нужна, чтобы не логиниться заново при каждом открытии приложения.
class Session {
  static const _tokenKey = 'auth_token';

static const _loginKey = 'saved_login';

  static const _accountIdKey = 'saved_account_id';

static Future<void> saveLogin(String login) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_loginKey, login);
}

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

static Future<String?> getLogin() async {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(_loginKey);
  if (cached != null) return cached;
  return _fetchAndCacheAccountInfo(loginOnly: true);
}

static Future<String?> getAccountId() async {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(_accountIdKey);
  if (cached != null) return cached;
  return _fetchAndCacheAccountInfo(loginOnly: false);
}

static Future<String?> _fetchAndCacheAccountInfo({required bool loginOnly}) async {
  final token = await getToken();
  if (token == null) return null;
  final info = await ApiClient().getMyAccountInfo(token);
  if (info == null) return null;
  await saveLogin(info.login);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_accountIdKey, info.accountId);
  return loginOnly ? info.login : info.accountId;
}
}
