import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../services/avatar_cache.dart';
import '../services/call_service.dart';
import '../services/pip_service.dart';
import '../session.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_settings_tile.dart';
import '../widgets/peer_name_text.dart';
import '../widgets/theme_reactive.dart';
import 'call_screen.dart';

/// Кто звонит — определяется по [peerDeviceId] АСИНХРОННО, уже ВНУТРИ этого
/// экрана (см. initState/_resolvePeerIdentity), а не заранее вызывающей
/// стороной. Раньше HomePlaceholderScreen сам дожидался сетевого
/// getDeviceOwnerInfo() и только потом пушил этот экран — на заблокированном
/// устройстве это означало, что самый обычный список чатов (уже
/// нарисованный под этим экраном, см. MainActivity.applyLockScreenFlagsIfNeeded
/// про showWhenLocked) был реально виден и кликабелен всё время сетевого
/// запроса. Теперь экран показывается МГНОВЕННО (с заглушкой "неизвестный"),
/// имя подставляется следующим кадром, как только придёт ответ.
class IncomingCallScreen extends StatefulWidget {
  final String peerDeviceId;
  const IncomingCallScreen({super.key, required this.peerDeviceId});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<CallState>? _stateSub;
  bool _navigatedAway = false;
  Future<Uint8List?>? _peerAvatarFuture;
  String _peerLogin = '';
  String _peerAccountId = '';

  @override
  void initState() {
    super.initState();
    debugPrint(
      'IncomingCallScreen: initState (peerDeviceId=${widget.peerDeviceId})',
    );
    CallService.instance.setCallUiOnTop(true);
    _resolvePeerIdentity();
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
    // НЕ снимаем безусловно — если мы уходим потому что CallScreen уже
    // пушится поверх нас (принятие звонка, см. removeRoute-комментарий выше
    // и pushReplacement у кнопки "Принять"), флаг должен остаться true без
    // единого кадра "false посередине" (CallLockShield иначе на миг покажет
    // щит между этим dispose() и CallScreen.initState()). CallScreen сам
    // выставит true в своём initState ДО того, как этот dispose() вообще
    // вызовется (Flutter строит новый route перед тем, как выгрузить
    // старый) — поэтому здесь достаточно просто ничего не трогать, если
    // экран звонка всё ещё где-то на сцене.
    if (!CallService.instance.isCallScreenVisible) {
      CallService.instance.setCallUiOnTop(false);
    }
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _resolvePeerIdentity() async {
    final token = await Session.getToken();
    if (token == null || !mounted) return;
    final owner = await ApiClient().getDeviceOwnerInfo(
      token,
      widget.peerDeviceId,
    );
    if (owner == null || !mounted) return;
    setState(() {
      _peerLogin = owner.login;
      _peerAccountId = owner.accountId;
      _peerAvatarFuture = AvatarCache.get(owner.accountId);
    });
  }

  bool _leavingScreen = false;

  /// Системный «назад» (кнопка/жест) с этого экрана — так же, как и на
  /// CallScreen (см. там подробный комментарий), недопустим без
  /// разблокировки, пока экран показан ПОВЕРХ заблокированного телефона:
  /// иначе свайп назад открывал бы обычный список чатов ПОД этим экраном,
  /// хотя пароль устройства ни разу не вводился. Кнопки "Принять"/"Отклонить"
  /// ниже зовут Navigator.pop/pushReplacement НАПРЯМУЮ (программный pop,
  /// PopScope его не перехватывает) — этим ограничением не связаны, отклонить
  /// звонок можно и с локскрина, как трубку кладут в обычном телефоне.
  Future<void> _leaveIncomingScreen(VoidCallback proceed) async {
    if (_leavingScreen) return;
    _leavingScreen = true;
    try {
      if (await PipService.isDeviceLocked()) {
        final unlocked = await PipService.requestUnlock();
        if (!unlocked) return; // остаёмся на экране входящего звонка
      }
      if (mounted) proceed();
    } finally {
      _leavingScreen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _leaveIncomingScreen(() {
          if (mounted) Navigator.of(context).pop();
        });
      },
      child: ThemeReactive(builder: (context) => _build(context)),
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            FutureBuilder<Uint8List?>(
              future: _peerAvatarFuture,
              builder: (context, snapshot) =>
                  AvatarThumbnail(bytes: snapshot.data, radius: 56),
            ),
            const SizedBox(height: 20),
            _peerAccountId.isEmpty
                ? Text(
                    _peerLogin.isEmpty ? tr('common.unknown') : _peerLogin,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 24,
                    ),
                  )
                : PeerNameText(
                    accountId: _peerAccountId,
                    fallbackLogin: _peerLogin,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 24,
                    ),
                  ),
            const SizedBox(height: 8),
            Text(
              tr('call.incoming'),
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
                          builder: (context) => CallScreen(
                            peerLogin: _peerLogin,
                            peerAccountId: _peerAccountId,
                          ),
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
