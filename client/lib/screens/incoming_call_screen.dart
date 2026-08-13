import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/call_service.dart';
import '../theme/app_theme.dart';
import 'call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  final String peerLogin;
  const IncomingCallScreen({super.key, required this.peerLogin});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<CallState>? _stateSub;
  bool _navigatedAway = false;

  @override
  void initState() {
    super.initState();
    debugPrint('IncomingCallScreen: initState (peerLogin=${widget.peerLogin})');
    // Звонящий мог сбросить вызов (или он сам оборвался) до того, как мы
    // ответили/отклонили — CallService в этом случае сам уходит в idle
    // (и останавливает мелодию), но экран "кто звонит" без этой подписки
    // остаётся висеть на месте. Та же подписка ловит и автопринятие
    // (кнопка "Ответить" в push-уведомлении, см. CallService._autoAcceptAndOpenScreen) —
    // состояние меняется на connected, этот экран должен САМ убраться,
    // открывая дорогу CallScreen, который в это время пушится поверх.
    //
    // ВАЖНО: НЕ Navigator.pop() — при автопринятии CallService независимо
    // ПУШИТ CallScreen поверх этого экрана в реакции на тот же самый переход
    // состояния, и порядок между этими двумя обработчиками не гарантирован.
    // Если наш pop() срабатывает уже ПОСЛЕ того как CallScreen успел
    // запушиться, pop() убирает верхний элемент стека — то есть свежий
    // CallScreen, а не себя! Экран внешне "не переключался" именно поэтому:
    // CallScreen пушился и тут же выкидывался обратно. removeRoute() убирает
    // именно СВОЙ маршрут, независимо от того, где он сейчас в стеке.
    _stateSub = CallService.instance.stateStream.listen((state) {
      debugPrint(
        'IncomingCallScreen: stateStream -> $state (navigatedAway=$_navigatedAway, mounted=$mounted)',
      );
      if (_navigatedAway || !mounted) return;
      if (state != CallState.incomingRinging) {
        _navigatedAway = true;
        final route = ModalRoute.of(context);
        debugPrint(
          'IncomingCallScreen: ухожу с экрана сам (removeRoute), route=$route',
        );
        if (route != null) {
          Navigator.of(context).removeRoute(route);
        }
      }
    });
  }

  @override
  void dispose() {
    debugPrint('IncomingCallScreen: dispose');
    _stateSub?.cancel();
    super.dispose();
  }

  String get peerLogin => widget.peerLogin;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const CircleAvatar(radius: 56, child: Icon(Icons.person, size: 56)),
            const SizedBox(height: 20),
            Text(
              peerLogin,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 24,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Входящий звонок',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _actionButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    onTap: () {
                      _navigatedAway = true;
                      CallService.instance.declineCall();
                      Navigator.pop(context);
                    },
                  ),
                  _actionButton(
                    icon: Icons.call,
                    color: Colors.green,
                    onTap: () {
                      _navigatedAway = true;
                      // Не ждём — экран разговора открывается сразу, а сам
                      // обмен WebRTC идёт уже на нём (см. CallService.statusUpdates).
                      CallService.instance.acceptCall();
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              CallScreen(peerLogin: peerLogin),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }
}
