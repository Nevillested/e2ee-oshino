import 'package:flutter/material.dart';
import 'navigator_key.dart';
import 'screens/splash_screen.dart';
import 'services/debug_log.dart';
import 'storage/locale_store.dart';
import 'storage/text_scale_store.dart';
import 'storage/theme_store.dart';
import 'theme/app_theme.dart';
import 'widgets/app_lock_gate.dart';
import 'widgets/system_pip_video_view.dart';

void main() {
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
    // Разовая чистка разросшегося debug_log.txt у уже установленных
    // пользователей (см. DebugLog.resetOnceIfNeeded) — не блокирует старт.
    DebugLog.resetOnceIfNeeded();
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
              child: AppLockGate(
                child: Stack(
                  children: [
                    if (child != null) child,
                    const SystemPipVideoView(),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
