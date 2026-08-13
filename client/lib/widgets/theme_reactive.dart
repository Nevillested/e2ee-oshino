import 'package:flutter/material.dart';
import '../storage/locale_store.dart';
import '../storage/theme_store.dart';

/// Оборачивает build() экрана, который читает AppColors.* и/или tr(...) —
/// без этого смена темы или языка в настройках не перерисовала бы уже
/// смонтированные экраны (оба — обычные статические поля, не
/// InheritedWidget, Flutter сам не знает, что их нужно перечитать).
/// AnimatedBuilder на объединении обоих notifier'ов триггерит только
/// rebuild (build() экрана вызывается заново и подхватывает новые цвета/
/// текст), само State виджета не пересоздаётся — активные подписки,
/// контроллеры и соединения внутри экрана не прерываются.
class ThemeReactive extends StatelessWidget {
  const ThemeReactive({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([ThemeStore.notifier, LocaleStore.notifier]),
      builder: (context, _) => builder(context),
    );
  }
}
