import 'dart:async';

/// Живой процент загрузки конкретного сообщения — тот же принцип, что и у
/// MessageRouter.incomingDeletes: PendingSendRetrier грузит файл в фоне (не
/// привязан к тому, открыт ли сейчас ChatScreen нужного собеседника), и
/// единственный способ дотянуться до _uploadProgress конкретного экрана —
/// широковещательный стрим, на который ChatScreen подписывается сам (см.
/// разбор пользовательских логов: при повторной отправке после реконнекта
/// процент вообще не показывался, потому что PendingSendRetrier раньше
/// никак не мог его никому передать).
class UploadProgressBus {
  UploadProgressBus._();

  static final _controller =
      StreamController<(String messageId, double percent)>.broadcast();

  static Stream<(String messageId, double percent)> get stream =>
      _controller.stream;

  static void emit(String messageId, double percent) {
    _controller.add((messageId, percent));
  }
}
