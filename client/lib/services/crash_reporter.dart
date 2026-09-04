import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../session.dart';
import 'debug_log.dart';

/// Автоматическая тихая отправка диагностического лога на сервер при
/// настоящих ошибках — раньше пользователя приходилось просить прислать
/// файл вручную (кнопки "Отзыв"/"Поделиться логом" в "О приложении", см.
/// историю about_screen.dart, теперь убраны, это их замена). Триггерится
/// ТОЛЬКО из DebugLog.error() — то есть из мест в коде, явно отмеченных как
/// действительно проблемные (см. их список в местах вызова), а не из
/// каждой diagnostic-строки подряд.
///
/// Лог по дизайну самого DebugLog не должен содержать содержимого сообщений
/// (см. class-comment там) — только метаданные (device_id, состояния,
/// коды ошибок, счётчики). Это то же самое, что сервер и так легитимно
/// видит про переписку (кто с кем на связи, метаданные звонков — см.
/// "Границы доверия" в OSHINOBU_OVERVIEW.md), новую границу доверия
/// автоотправка не пересекает.
class CrashReporter {
  CrashReporter._();

  // Не чаще раза в 30 минут — иначе одна зациклившаяся ошибка (реальный
  // прошлый кейс: одно и то же сообщение передоставлялось каждые ~20с
  // 36+ минут подряд) завалит таблицу feedback сотнями одинаковых отчётов
  // за один и тот же инцидент. Персистентно в SharedPreferences, а не
  // только в памяти — переживает перезапуск процесса посреди цикла ошибок.
  static const _minInterval = Duration(minutes: 30);
  static const _lastSentKey = 'crash_reporter_last_sent_at_ms';

  // На всякий случай ограничиваем то, что реально уходит по сети: сам
  // DebugLog капает файл на 1 МБ, но с запасом (JSON-экранирование кавычек/
  // переводов строк) шлём максимум последние 500 КБ — сама ошибка,
  // вызвавшая отчёт, только что дописана в КОНЕЦ файла, так что хвост —
  // как раз то, что нужно.
  static const _maxUploadChars = 500 * 1000;

  static bool _sending = false;

  static void init() {
    DebugLog.setErrorHook(_onError);
  }

  static void _onError() {
    if (_sending) return;
    unawaited(_maybeReport());
  }

  static Future<void> _maybeReport() async {
    _sending = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_lastSentKey);
      if (lastMs != null) {
        final elapsed = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(lastMs),
        );
        if (elapsed < _minInterval) return;
      }

      // Отправлять некому/некуда, если пользователь ещё не залогинен
      // (ошибка на экране приветствия/входа) — эндпоинт требует токен
      // сессии. Лог при этом никуда не девается, останется в файле до
      // следующей подходящей ошибки уже после входа.
      final token = await Session.getToken();
      if (token == null) return;

      final file = await DebugLog.getFile();
      if (!await file.exists()) return;
      var text = await file.readAsString();
      text = text.trim();
      if (text.isEmpty) return;
      if (text.length > _maxUploadChars) {
        text = text.substring(text.length - _maxUploadChars);
      }

      await ApiClient().reportCrashLog(token, text);
      await prefs.setInt(_lastSentKey, DateTime.now().millisecondsSinceEpoch);
      await DebugLog.clear();
    } catch (_) {
      // Отчёт не критичен для работы приложения — молча теряем попытку,
      // при следующей достаточно серьёзной ошибке (не раньше _minInterval)
      // попробуем снова, лог за это время никуда не пропадёт.
    } finally {
      _sending = false;
    }
  }
}
