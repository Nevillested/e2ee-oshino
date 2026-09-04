import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'navigator_key.dart';
import 'screens/splash_screen.dart';
import 'services/crash_reporter.dart';
import 'services/debug_log.dart';
import 'services/keyboard_insets.dart';
import 'storage/partial_download_store.dart';
import 'storage/locale_store.dart';
import 'storage/text_scale_store.dart';
import 'storage/theme_store.dart';
import 'theme/app_theme.dart';
import 'widgets/app_lock_gate.dart';
import 'widgets/call_lock_shield.dart';
import 'widgets/system_pip_video_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Единая точка, куда стекаются ВСЕ невыловленные ошибки — и синхронные
  // ошибки фреймворка (FlutterError.onError), и асинхронные ошибки вне
  // зоны (PlatformDispatcher.onError). Пишем их в debug_log.txt с первыми
  // кадрами стека и причиной — DebugLog.error() (а не .log()) вдобавок
  // будит CrashReporter, который тихо, без единого диалога, шлёт лог на
  // сервер (см. её собственный comment про троттлинг/приватность). НИКОГДА
  // не логируем содержимое сообщений — сюда попадает только текст ошибки и
  // трасса, но осторожность не лишняя.
  CrashReporter.init();
  final priorOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final frames = details.stack?.toString().split('\n').take(4).join(' | ');
    DebugLog.error(
      'FlutterError: ${details.exceptionAsString()}'
      '${details.library != null ? ' [${details.library}]' : ''}'
      '${frames != null ? ' @ $frames' : ''}',
    );
    priorOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    DebugLog.error(
      'Uncaught: $error @ ${stack.toString().split('\n').take(4).join(' | ')}',
    );
    // Не роняем всё приложение из-за одиночной невыловленной асинхронной
    // ошибки — она записана (и уходит в CrashReporter), этого достаточно
    // для разбора.
    return true;
  };

  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  @override
  void initState() {
    super.initState();
    // Не await — не блокируем первый кадр ради чтения сохранённых настроек;
    // соответствующий notifier сам уведомит AnimatedBuilder ниже, когда
    // значение прочитается (обычно за один кадр, разницы не видно).
    ThemeStore.init();
    LocaleStore.init();
    TextScaleStore.init();
    // См. KeyboardInsets — как можно раньше, чтобы нативный поток высоты
    // клавиатуры уже был подписан к моменту, когда пользователь впервые
    // откроет чат и коснётся поля ввода.
    KeyboardInsets.start();
    // Разовая чистка разросшегося debug_log.txt у уже установленных
    // пользователей (см. DebugLog.resetOnceIfNeeded) — не блокирует старт.
    DebugLog.resetOnceIfNeeded();
    // Недокачанные хвосты скачиваний, к которым давно не возвращались, —
    // просто занятое место (см. PartialDownloadStore). Не блокирует старт.
    PartialDownloadStore.pruneStale();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeStore.notifier,
        LocaleStore.notifier,
        TextScaleStore.notifier,
      ]),
      builder: (context, _) {
        return MaterialApp(
          title: 'Oshinobu',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          theme: buildAppTheme(),
          home: const SplashScreen(),
          // builder оборачивает ЛЮБОЙ текущий экран — так во время настоящего
          // системного PiP поверх него оказывается видео собеседника (см.
          // SystemPipVideoView), а не тот экран, что случайно оказался открыт
          // под капотом в момент входа в PiP. Тут же навязываем выбранный в
          // настройках масштаб текста через MediaQuery — единая точка,
          // работает сразу для ВСЕХ экранов без правки каждого по
          // отдельности (обычные Text без явного textScaler наследуют его
          // из ближайшего MediaQuery).
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(TextScaleStore.notifier.value),
              ),
              // CallLockShield — САМЫЙ внешний слой, поверх даже AppLockGate:
              // должен уметь скрыть вообще всё приложение (включая экран
              // ввода PIN) на заблокированном по звонку телефоне, см. его
              // собственный подробный комментарий про то, какую дыру он
              // закрывает.
              child: CallLockShield(
                child: AppLockGate(
                  child: Stack(
                    children: [
                      if (child != null) child,
                      const SystemPipVideoView(),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
