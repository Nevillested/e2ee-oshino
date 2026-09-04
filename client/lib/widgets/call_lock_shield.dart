import 'dart:async';
import 'package:flutter/material.dart';
import '../services/call_service.dart';
import '../services/pip_service.dart';
import '../theme/app_theme.dart';
import 'app_loading_indicator.dart';

/// Последний рубеж защиты заблокированного телефона от входящего звонка.
///
/// MainActivity ставит `setShowWhenLocked(true)` на СЕБЯ ЦЕЛИКОМ (см.
/// `applyLockScreenFlagsIfNeeded` в MainActivity.kt) — это ОДНА Activity на
/// всё Flutter-приложение, значит ЛЮБОЙ Flutter-экран, оказавшийся видимым в
/// этот момент (список чатов, открытый чат с сообщениями, настройки — что
/// угодно, что было на экране ДО звонка или успело построиться, пока
/// разрешалось, кто звонит), рисуется поверх системного локскрина БЕЗ
/// единого введённого пароля. Единственные два экрана, которым это
/// осознанно разрешено — IncomingCallScreen и CallScreen (они сами просят
/// разблокировку перед тем как пустить дальше, см. их PopScope +
/// `_leaveCallScreen`/`_leaveIncomingScreen`).
///
/// Раньше между "показать поверх локскрина" (нативно, мгновенно) и "открыт
/// именно экран звонка" (во Flutter, после сетевых round-trip'ов —
/// getDeviceOwnerInfo, acceptCall) было окно в секунды, где по-настоящему
/// видно и кликабельно было что угодно из уже открытого приложения — так
/// нашёлся баг (список чатов на заблокированном телефоне при входящем
/// звонке; при автопринятии кнопкой "Ответить" в уведомлении окно ещё
/// больше — там ждём ещё и acceptCall()). Патчить каждую точку, где это
/// окно могло возникнуть, ненадёжно — новая такая точка появится с любым
/// следующим сценарием звонка. Вместо этого — системный щит: оборачивает
/// ВСЁ приложение (см. main.dart) и держит непрозрачную заглушку поверх
/// ЛЮБОГО текущего экрана, пока телефон физически заблокирован
/// (`PipService.isDeviceLocked()`) И ни один легитимный экран звонка ещё не
/// на сцене (`CallService.isCallUiOnTop`, выставляют сами IncomingCallScreen
/// и CallScreen в initState/dispose).
class CallLockShield extends StatefulWidget {
  final Widget child;
  const CallLockShield({super.key, required this.child});

  @override
  State<CallLockShield> createState() => _CallLockShieldState();
}

class _CallLockShieldState extends State<CallLockShield>
    with WidgetsBindingObserver {
  // По умолчанию — ЩИТ ВКЛЮЧЁН. Самый первый кадр вполне может оказаться
  // тем самым кадром, что рисуется поверх локскрина (холодный старт по
  // входящему звонку) — нельзя ни на миг по умолчанию считать "не
  // заблокировано", пока не спросили систему напрямую. Тот же принцип, что
  // и в AppLockGate._ready — держим худший случай, пока не доказано
  // обратное; реальный ответ MethodChannel почти всегда укладывается в один
  // кадр, так что на не-locked/не-call сценарии это незаметно.
  bool _locked = true;
  bool _callUiOnTop = CallService.instance.isCallUiOnTop;
  StreamSubscription<bool>? _callUiSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshLocked();
    _callUiSub = CallService.instance.callUiOnTopUpdates.listen((visible) {
      if (!mounted) return;
      setState(() => _callUiOnTop = visible);
      // Экран звонка мог как раз убраться (отклонили/завершили) или только
      // появиться — в обоих случаях самое время перепроверить настоящее
      // состояние блокировки заново, а не полагаться на устаревшее значение.
      _refreshLocked();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _callUiSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshLocked() async {
    final locked = await PipService.isDeviceLocked();
    if (mounted) setState(() => _locked = locked);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshLocked();
  }

  @override
  Widget build(BuildContext context) {
    final showShield = _locked && !_callUiOnTop;
    return Stack(
      children: [
        widget.child,
        if (showShield)
          ColoredBox(
            color: AppColors.background,
            child: Center(child: AppLoadingIndicator()),
          ),
      ],
    );
  }
}
