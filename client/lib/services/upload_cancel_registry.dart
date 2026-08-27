import 'package:dio/dio.dart' as dio;

/// Реестр активных CancelToken'ов текущих загрузок медиа на сервер, по
/// messageId — единственный способ по-настоящему прервать УЖЕ ИДУЩИЙ
/// сетевой запрос (см. cancelSend в chat_screen.dart). Без этого "отмена"
/// лишь убирала локальные следы сообщения, а сама HTTP-загрузка молча
/// донашивала себя в фоне до конца (см. media_upload.dart —
/// uploadAndDescribeMedia регистрирует токен здесь на время загрузки).
class UploadCancelRegistry {
  UploadCancelRegistry._();

  static final Map<String, dio.CancelToken> _tokens = {};

  static dio.CancelToken register(String messageId) {
    final token = dio.CancelToken();
    _tokens[messageId] = token;
    return token;
  }

  static void unregister(String messageId) {
    _tokens.remove(messageId);
  }

  /// Не найден — значит загрузка либо уже закончилась, либо не начиналась
  /// (например, сообщение ещё на этапе шифрования) — молча ничего не
  /// делаем, дальнейшую зачистку локальных следов делает вызывающий код.
  static void cancel(String messageId) {
    final token = _tokens.remove(messageId);
    if (token != null && !token.isCancelled) {
      token.cancel('cancelled by user');
    }
  }
}
