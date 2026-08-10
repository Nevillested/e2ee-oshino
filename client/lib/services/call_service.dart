import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../crypto/key_store.dart';
import 'websocket_service.dart';
import '../api/api_client.dart';
import '../session.dart';
import 'sound_service.dart';

enum CallState { idle, outgoingRinging, incomingRinging, connected, ended }

class IncomingCallInfo {
  final String callId;
  final String peerDeviceId;
  IncomingCallInfo(this.callId, this.peerDeviceId);
}

class CallService {
  CallService._internal();
  static final CallService instance = CallService._internal();

  static const _uuid = Uuid();

  Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  Future<void> _refreshIceServers() async {
    final token = await Session.getToken();
    if (token == null) return;
    final creds = await ApiClient().getTurnCredentials(token);
    if (creds == null) return;

    _iceServers = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': creds['urls'],
          'username': creds['username'],
          'credential': creds['password'],
        },
      ],
    };
  }

  RTCPeerConnection? _peerConnection;
  MediaStream? localStream;
  MediaStreamTrack? _videoTrack;

  String? _callId;
  String? _peerDeviceId;
  String? _pendingOfferSdp;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  final _stateController = StreamController<CallState>.broadcast();
  final _incomingCallController = StreamController<IncomingCallInfo>.broadcast();
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();

  /// Сигнал о том, включена ли камера у СОБЕСЕДНИКА прямо сейчас.
  bool remoteVideoEnabled = false;
  final _remoteVideoStateController = StreamController<bool>.broadcast();
  Stream<bool> get remoteVideoStateUpdates => _remoteVideoStateController.stream;

  Stream<CallState> get stateStream => _stateController.stream;
  Stream<IncomingCallInfo> get incomingCalls => _incomingCallController.stream;
  Stream<MediaStream?> get remoteStreamUpdates => _remoteStreamController.stream;

  CallState _state = CallState.idle;
  CallState get state => _state;

  bool micEnabled = true;
  bool videoEnabled = false;
  bool speakerOn = false;

  bool _listenerStarted = false;

  void startListening() {
    if (_listenerStarted) return;
    _listenerStarted = true;
    WebSocketService.instance.callSignals.listen(_handleSignal);
  }

void _setState(CallState s) {
  _state = s;
  _stateController.add(s);

  if (s == CallState.outgoingRinging) {
    SoundService.startRingback();
  } else {
    SoundService.stopRingback();
  }

  if (s == CallState.incomingRinging) {
    SoundService.startRingtone();
  } else {
    SoundService.stopRingtone();
  }
}

  Future<void> _send(String type, Map<String, dynamic> payload) async {
    if (_peerDeviceId == null) return;
    final myDeviceId = await KeyStore.getStoredDeviceId();
    WebSocketService.instance.sendCallSignal(_peerDeviceId!, type, {
      ...payload,
      'sender_device_id': myDeviceId,
      'call_id': _callId,
    });
  }

  Future<void> _createPeerConnection() async {
    await _refreshIceServers();
    _peerConnection = await createPeerConnection(_iceServers);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _send('call_ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStreamController.add(event.streams.first);
      }
    };

    _peerConnection!.onConnectionState = (connState) {
      if (connState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setState(CallState.connected);
      } else if (connState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        endCall();
      }
    };

    // Срабатывает, когда мы добавляем/убираем дорожку (например, включаем
    // видео посреди разговора) — соединение уже установлено, поэтому
    // нужно провести повторное согласование (renegotiation), а не полный
    // новый звонок.
    _peerConnection!.onRenegotiationNeeded = () async {
      if (_state != CallState.connected) return;
      await _renegotiate();
    };
  }

  Future<void> _renegotiate() async {
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    await _send('call_offer', {'sdp': offer.sdp, 'renegotiation': true});
  }

  /// Открываем ТОЛЬКО микрофон при старте звонка — камера не трогается
  /// вообще, пока пользователь явно не нажмёт "включить видео". Раньше
  /// камера захватывалась всегда (даже для чисто голосового звонка), что
  /// на части устройств (замечено на Pixel 3) вызывало конфликт нативного
  /// слоя камеры с отрисовкой Flutter — короткая вспышка интерфейса и
  /// чёрный экран сразу после ответа на звонок.
Future<void> _openLocalAudio() async {
  localStream = await navigator.mediaDevices.getUserMedia({'audio': true});
  for (final track in localStream!.getAudioTracks()) {
    track.enabled = micEnabled;
  }
  for (final track in localStream!.getTracks()) {
    await _peerConnection!.addTrack(track, localStream!);
  }

  // Явно фиксируем маршрут звука через ушной динамик сразу после
  // открытия микрофона — без этого Android иногда выбирает какой-то
  // промежуточный/гибридный маршрут по умолчанию, который звучит
  // непривычно, пока пользователь не переключит вывод звука вручную
  // (что как раз и заставляет систему выбрать маршрут заново явно).
  speakerOn = false;
  await Helper.setSpeakerphoneOn(false);
}

  Future<void> startCall(String peerDeviceId) async {
    _callId = _uuid.v4();
    _peerDeviceId = peerDeviceId;
    micEnabled = true;
    videoEnabled = false;
    remoteVideoEnabled = false;
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();

    _setState(CallState.outgoingRinging);

    await _createPeerConnection();
    await _openLocalAudio();

    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    await _send('call_offer', {'sdp': offer.sdp});
  }

  Future<void> acceptCall() async {
    if (_pendingOfferSdp == null) return;

    micEnabled = true;
    videoEnabled = false;
    remoteVideoEnabled = false;

    await _createPeerConnection();
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(_pendingOfferSdp!, 'offer'),
    );
    _remoteDescriptionSet = true;
    for (final candidate in _pendingRemoteCandidates) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();

    await _openLocalAudio();

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    await _send('call_answer', {'sdp': answer.sdp});
    _setState(CallState.connected);
  }

  Future<void> declineCall() async {
    await _send('call_reject', {});
    _resetLocal();
  }

  Future<void> cancelCall() async {
    await _send('call_cancel', {});
    _resetLocal();
  }

  Future<void> endCall({bool notifyRemote = true}) async {
    if (notifyRemote && _peerDeviceId != null) {
      await _send('call_end', {});
    }
    _resetLocal();
  }

  void _resetLocal() {
    for (final track in localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    localStream?.dispose();
    localStream = null;
    _videoTrack?.stop();
    _videoTrack = null;
    _peerConnection?.close();
    _peerConnection = null;
    _pendingOfferSdp = null;
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();
    _peerDeviceId = null;
    _callId = null;
    videoEnabled = false;
    _remoteStreamController.add(null);
    remoteVideoEnabled = false;
    _remoteVideoStateController.add(false);
    _setState(CallState.idle);
  }

  Future<void> toggleMic() async {
    micEnabled = !micEnabled;
    for (final track in localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = micEnabled;
    }
  }

  /// Камера открывается только здесь, лениво, при первом включении видео
  /// за весь звонок. Повторные вкл/выкл после этого — просто флаг
  /// enabled на уже существующей дорожке, без повторного захвата камеры.
  Future<void> toggleVideo() async {
    videoEnabled = !videoEnabled;

    if (videoEnabled && _videoTrack == null) {
      final videoStream = await navigator.mediaDevices.getUserMedia({
        'video': {'facingMode': 'user'},
      });
      _videoTrack = videoStream.getVideoTracks().first;
      localStream?.addTrack(_videoTrack!);
      await _peerConnection?.addTrack(_videoTrack!, localStream!);
      // addTrack сам вызовет onRenegotiationNeeded — отдельно дожимать не нужно.
    } else {
      _videoTrack?.enabled = videoEnabled;
    }

    await _send('call_video_state', {'enabled': videoEnabled});
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await Helper.setSpeakerphoneOn(speakerOn);
  }

  Future<void> _handleSignal(Map<String, dynamic> payload) async {
    final type = payload['type'] as String?;
    final senderDeviceId = payload['sender_device_id'] as String?;

    switch (type) {
      case 'call_offer':
        if (senderDeviceId == null) return;
        final isRenegotiation = payload['renegotiation'] == true;

        if (isRenegotiation && _peerConnection != null) {
          // Повторное согласование внутри уже идущего звонка (например,
          // собеседник только что включил видео) — не новый вызов.
          final sdp = payload['sdp'] as String?;
          if (sdp == null) return;
          await _peerConnection!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
          final answer = await _peerConnection!.createAnswer();
          await _peerConnection!.setLocalDescription(answer);
          await _send('call_answer', {'sdp': answer.sdp});
          return;
        }

        _callId = payload['call_id'] as String?;
        _peerDeviceId = senderDeviceId;
        _pendingOfferSdp = payload['sdp'] as String?;
        _setState(CallState.incomingRinging);
        _incomingCallController.add(IncomingCallInfo(_callId ?? '', senderDeviceId));
        break;

      case 'call_answer':
        final sdp = payload['sdp'] as String?;
        if (sdp == null || _peerConnection == null) return;
        await _peerConnection!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        _remoteDescriptionSet = true;
        for (final candidate in _pendingRemoteCandidates) {
          await _peerConnection!.addCandidate(candidate);
        }
        _pendingRemoteCandidates.clear();
        break;

      case 'call_ice':
        final candidate = RTCIceCandidate(
          payload['candidate'] as String?,
          payload['sdpMid'] as String?,
          payload['sdpMLineIndex'] as int?,
        );
        if (_remoteDescriptionSet && _peerConnection != null) {
          await _peerConnection!.addCandidate(candidate);
        } else {
          _pendingRemoteCandidates.add(candidate);
        }
        break;

      case 'call_video_state':
        remoteVideoEnabled = payload['enabled'] as bool? ?? false;
        _remoteVideoStateController.add(remoteVideoEnabled);
        break;

      case 'call_reject':
      case 'call_busy':
      case 'call_cancel':
      case 'call_end':
      case 'call_unavailable':
        _resetLocal();
        break;
    }
  }
}