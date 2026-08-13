import 'package:flutter/material.dart';
import 'navigator_key.dart';
import 'screens/splash_screen.dart';
import 'storage/locale_store.dart';
import 'storage/theme_store.dart';
import 'theme/app_theme.dart';
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
    // Не await — не блокируем первый кадр ради чтения сохранённой темы;
    // ThemeStore.notifier сам уведомит ValueListenableBuilder ниже, когда
    // значение прочитается (обычно за один кадр, разницы не видно).
    ThemeStore.init();
    LocaleStore.init();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([ThemeStore.notifier, LocaleStore.notifier]),
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
          // под капотом в момент входа в PiP.
          builder: (context, child) {
            return Stack(
              children: [if (child != null) child, const SystemPipVideoView()],
            );
          },
        );
      },
    );
  }
}
