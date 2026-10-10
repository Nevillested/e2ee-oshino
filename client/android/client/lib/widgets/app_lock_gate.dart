import 'package:flutter/material.dart';
import '../screens/app_lock_screen.dart';
import '../services/app_lock_store.dart';

/// Оборачивает ВСЁ приложение (см. main.dart) — единственное место, где
/// решается, показывать ли поверх текущего экрана полноэкранную
/// блокировку (app_lock_screen.dart), вместо того чтобы встраивать эту
/// проверку в каждый экран по отдельности.
class AppLockGate extends StatefulWidget {
  final Widget child;

  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  DateTime? _backgroundedAt;
  // "Пройдены ли ворота" для ТЕКУЩЕЙ сессии на переднем плане — true, если
  // либо блокировка не была включена на момент старта, либо пользователь
  // только что успешно её прошёл. Специально НЕ сбрасывается сам по себе,
  // когда пользователь включает блокировку прямо в настройках посреди уже
  // идущей сессии — иначе экран блокировки вылезал бы сразу после того,
  // как человек только что сам её настроил, что бессмысленно (он и так
  // только что подтвердил, что это он, дважды введя новый PIN).
  bool _passedGate = false;
  // Пока не прочитали сохранённые настройки с диска — ничего не решаем и
  // не показываем реальный контент: единственный момент, где действительно
  // нужно придержать самый первый кадр, иначе на холодном старте с уже
  // включённой блокировкой был бы шанс на долю секунды показать содержимое
  // приложения ДО того, как мы вообще узнали, что блокировка включена.
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await AppLockStore.init();
    if (!mounted) return;
    setState(() {
      _passedGate = !AppLockStore.notifier.value.enabled;
      _ready = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_ready) return;
    final settings = AppLockStore.notifier.value;
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final bg = _backgroundedAt;
    _backgroundedAt = null;
    if (!settings.enabled || bg == null) return;
    if (DateTime.now().difference(bg) >=
        Duration(seconds: settings.timeoutSeconds)) {
      setState(() => _passedGate = false);
    }
  }

  void _unlock() => setState(() => _passedGate = true);

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const ColoredBox(color: Colors.black);

    return AnimatedBuilder(
      animation: AppLockStore.notifier,
      builder: (context, _) {
        final settings = AppLockStore.notifier.value;
        final showLock = settings.enabled && !_passedGate;
        return PopScope(
          canPop: !showLock,
          child: Stack(
            children: [
              widget.child,
              if (showLock) AppLockScreen(onUnlocked: _unlock),
            ],
          ),
        );
      },
    );
  }
}
