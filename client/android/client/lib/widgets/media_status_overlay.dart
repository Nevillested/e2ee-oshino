import 'package:flutter/material.dart';
import 'app_loading_indicator.dart';

/// Единый оверлей "текстовый статус / процент" ПО ЦЕНТРУ миниатюры —
/// общий для отправки (шифрование/очередь/загрузка на сервер) и получения
/// (скачивание) фото, видео и видео-сообщений (ТЗ пользователя). Раньше
/// статус отправки был мелкой полоской снизу — длинный текст там обрезался
/// многоточием, и процент из-за этого был просто не виден. Голосовые,
/// текстовые и обычные файлы (isFile) сюда не входят — им, по ТЗ
/// пользователя, оставлен прежний вид.
///
/// Текстовая подпись фазы ("В очереди…", "Шифрование…", "Загрузка на
/// сервер…", "Скачивание…") видна ВСЕГДА (ТЗ пользователя: "и при
/// скачивании, и при выгрузке должен быть текстовый статус на миниатюрке")
/// — просто пока идёт РЕАЛЬНАЯ передача байт (percent != null), над ней ещё
/// и крупное число %; на остальных фазах (в очереди, шифрование и т.п.,
/// percent == null) вместо числа — маленький спиннер.
class MediaStatusOverlay extends StatelessWidget {
  final String statusText;
  final double? percent;
  final double size;
  final BorderRadius? borderRadius;

  /// ТЗ пользователя: кнопка отмены скачивания — везде, где оно происходит.
  /// null — отмена недоступна в этом состоянии (например, идёт отправка на
  /// сервер, а не приём — см. её отдельный путь через UploadCancelRegistry
  /// и "Отменить отправку" в контекстном меню, не этот виджет).
  final VoidCallback? onCancel;

  const MediaStatusOverlay({
    super.key,
    required this.statusText,
    required this.percent,
    required this.size,
    this.borderRadius,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: borderRadius ?? BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (percent != null)
              Text(
                '${percent!.round()}%',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size < 150 ? 16 : 22,
                  fontWeight: FontWeight.w700,
                ),
              )
            else
              AppLoadingIndicator(
                size: size < 150 ? 16 : 20,
                color: Colors.white,
              ),
            const SizedBox(height: 6),
            Text(
              statusText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: size < 150 ? 10 : 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (onCancel != null) ...[
              const SizedBox(height: 6),
              GestureDetector(
                // opaque — сама плитка снаружи тоже кликабельна (обычно
                // "тап = открыть/начать скачивание"), кнопка отмены внутри
                // не должна дополнительно триггерить тот же тап поверх себя.
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.close,
                    color: Colors.white,
                    size: size < 150 ? 14 : 16,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
