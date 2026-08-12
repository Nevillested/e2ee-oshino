import 'package:flutter/material.dart';
import 'navigator_key.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/system_pip_video_view.dart';

void main() {
  runApp(
    MaterialApp(
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
          children: [
            if (child != null) child,
            const SystemPipVideoView(),
          ],
        );
      },
    ),
  );
}
