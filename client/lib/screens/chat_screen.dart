import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/media_cipher.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/streaming_file_cipher.dart';
import '../crypto/x3dh.dart';
import '../models/picked_media.dart';
import '../screens/call_screen.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../services/active_chat_tracker.dart';
import '../services/call_service.dart';
import '../services/keyboard_height_store.dart';
import '../services/send_lock.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/full_emoji_picker.dart';
import '../widgets/media_picker_sheet.dart';
import '../widgets/ongoing_call_banner.dart';

class ChatScreen extends StatefulWidget {
  final String peerDeviceId;
  final String peerAccountId;
  final String peerLogin;

  const ChatScreen({
    super.key,
    required this.peerDeviceId,
    required this.peerAccountId,
    required this.peerLogin,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static final Map<String, double> _savedScrollOffsets = {};

  static const int _autoDownloadLimitBytes = 10 * 1024 * 1024; // 10 МБ
  static const int _streamingThresholdBytes = 20 * 1024 * 1024; // 20 МБ
  static const int _maxAttachmentSizeBytes = 500 * 1024 * 1024; // 500 МБ

  final _textController = TextEditingController();
  final _textFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _apiClient = ApiClient();
  final Map<String, Future<Uint8List>> _mediaFutures = {};
  final Map<String, Uint8List> _resolvedMedia = {};
  final Map<String, Future<bool>> _existsChecks = {};
  final Map<String, Future<void>> _chunkedDownloads = {};

  String _currentPeerDeviceId = '';
  Map<String, dynamic>? _pendingInitHeader;
  bool _isPeerDeleted = false;
  bool _userAtBottom = true;
  bool _initialLoadComplete = false;
  int _lastMessageCount = 0;

  bool _emojiMode = false;
  double _keyboardHeight = 280;
  double _targetReserve = 0;
  bool _switchingMode = false;
  bool _hasText = false;

  List<StoredMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    ActiveChatTracker.currentPeerLogin = widget.peerLogin;
    ChatStore.clearUnread(widget.peerLogin);
    _currentPeerDeviceId = widget.peerDeviceId;
    _scrollController.addListener(_handleScroll);
    _textFocusNode.addListener(_onFocusChange);
    _textController.addListener(_onTextChanged);
    _loadKnownDeletedStatus();
    _loadHistory(initial: true);
    ChatStore.changes.listen((_) {
      _loadHistory();
    });
    KeyboardHeightStore.getKnownHeight().then((height) {
      if (mounted) setState(() => _keyboardHeight = height);
    });
  }

  void _onFocusChange() {
    if (_textFocusNode.hasFocus) {
      setState(() {
        _emojiMode = false;
        _targetReserve = _keyboardHeight;
      });
    } else {
      if (_switchingMode) {
        _switchingMode = false;
        return;
      }
      setState(() => _targetReserve = 0);
    }
  }

  void _onTextChanged() {
    final hasText = _textController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  Future<void> _loadKnownDeletedStatus() async {
    final peers = await ChatStore.getKnownPeers();
    final match = peers.where((p) => p.peerLogin == widget.peerLogin);
    if (match.isNotEmpty && mounted) {
      setState(() => _isPeerDeleted = match.first.isDeleted);
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    _userAtBottom =
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 40;
  }

  Future<void> _loadHistory({bool initial = false}) async {
    final messages = await ChatStore.getMessages(widget.peerLogin);
    if (!mounted) return;

    final countChanged = messages.length != _lastMessageCount;
    _lastMessageCount = messages.length;

    setState(() => _messages = messages);

    if (initial) {
      _initialLoadComplete = false;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(const Duration(milliseconds: 60));
        if (!mounted || !_scrollController.hasClients) return;
        final saved = _savedScrollOffsets[widget.peerLogin];
        if (saved != null && saved > 0) {
          _scrollController.jumpTo(saved.clamp(0, _scrollController.position.maxScrollExtent));
        } else {
          _scrollToBottom();
        }
        _initialLoadComplete = true;
      });
    } else if (_initialLoadComplete && _userAtBottom && countChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _refreshPeerDeviceId() async {
    try {
      final token = await Session.getToken();
      final result = await _apiClient.getDevicesByLogin(token!, widget.peerLogin);
      if (result.devices.isNotEmpty) {
        _currentPeerDeviceId = result.devices.first['device_id'] as String;
        await ChatStore.setLastKnownDeviceId(widget.peerLogin, _currentPeerDeviceId);
        await ChatStore.setPeerDeletedStatus(widget.peerLogin, false);
        if (mounted) setState(() => _isPeerDeleted = false);
      }
    } on ApiException catch (_) {
      await ChatStore.setPeerDeletedStatus(widget.peerLogin, true);
      if (mounted) setState(() => _isPeerDeleted = true);
    } catch (_) {
      // Сетевая ошибка — не трогаем текущий статус.
    }
  }

  void _startCall() {
    if (_isPeerDeleted) return;
    // Экран разговора должен открыться сразу — актуализация device_id и
    // сам обмен WebRTC идут уже в фоне, с живым статусом на самом экране
    // (см. CallService.statusUpdates), а не как задержка перед его показом.
    unawaited(_refreshPeerDeviceId());
    unawaited(CallService.instance.startCall(_currentPeerDeviceId));
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => CallScreen(peerLogin: widget.peerLogin)),
    );
  }

  Future<RatchetState> _ensureSessionForSending() async {
    await _refreshPeerDeviceId();
    var state = await SessionStore.getState(_currentPeerDeviceId);
    if (state != null) return state;

    final token = await Session.getToken();
    final myDeviceId = await KeyStore.getStoredDeviceId();
    final bundle = await _apiClient.getPrekeyBundle(token!, _currentPeerDeviceId);
    await PeerAccountStore.save(_currentPeerDeviceId, bundle['account_id'] as String);
    await PeerIdentityStore.save(_currentPeerDeviceId, bundle['identity_dh_pubkey'] as String);

    final outgoing = await establishOutgoingRoot(bundle: bundle, myDeviceId: myDeviceId!);
    state = await RatchetState.initAsSender(
      rootKey: outgoing.rootKey,
      ephemeralKeyPair: outgoing.ephemeralKeyPair,
    );
    _pendingInitHeader = outgoing.initHeader;
    return state;
  }

  Future<void> _handleSendPressed() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();
    await _sendTextMessage(text);
  }

  Future<void> _sendTextMessage(String text) async {
    final inner = InnerMessage.text(text);
    await ChatStore.addMessage(
      widget.peerLogin,
      StoredMessage(inner.messageId, text, true, inner.sentAt, status: 'sending'),
      accountId: widget.peerAccountId,
    );
    await _loadHistory();
    await _sendTextNetwork(text, inner.messageId);
  }

  Future<void> _sendTextNetwork(String text, String messageId) async {
    final inner = InnerMessage(
      messageId: messageId,
      type: 'text',
      sentAt: DateTime.now().millisecondsSinceEpoch,
      body: text,
    );

    try {
      await SendLock.run(widget.peerLogin, () async {
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);

        final encrypted = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encrypted,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        final status = await WebSocketService.instance.sendEnvelope(
          _currentPeerDeviceId,
          envelope,
          inner.messageId,
        );

        await ChatStore.updateMessageStatus(widget.peerLogin, inner.messageId, status);
      });
    } catch (_) {
      await ChatStore.updateMessageStatus(widget.peerLogin, messageId, 'failed');
    } finally {
      await _loadHistory();
    }
  }

  Future<void> _openAttachmentSheet() async {
    _textFocusNode.unfocus();
    setState(() {
      _emojiMode = false;
      _targetReserve = 0;
    });

    final result = await showMediaPickerSheet(context);

    if (result == 'open_camera') {
      final cameraResult = await Navigator.push<CameraCaptureResult>(
        context,
        MaterialPageRoute(builder: (context) => const CameraCaptureScreen()),
      );
      if (cameraResult != null) {
        await _sendPickedMedia([PickedMedia(file: cameraResult.file)], cameraResult.caption);
      }
      return;
    }

    if (result is MediaPickerSheetResult) {
      final files = <PickedMedia>[];
      for (final asset in result.items) {
        final file = await asset.file;
        if (file != null) {
          files.add(PickedMedia(file: file, isVideo: asset.type == AssetType.video));
        }
      }
      if (files.isNotEmpty) {
        await _sendPickedMedia(files, result.caption);
      }
    }
  }

  Future<void> _sendPickedMedia(List<PickedMedia> media, String caption) async {
    String? textMessageId;
    final queue = <({PickedMedia item, String messageId, int size, String fileName})>[];

    final hasCaption = caption.isNotEmpty;
    final groupId = (media.length + (hasCaption ? 1 : 0)) > 1
        ? 'grp_${DateTime.now().microsecondsSinceEpoch}'
        : null;

    if (hasCaption) {
      final inner = InnerMessage.text(caption);
      textMessageId = inner.messageId;
      await ChatStore.addMessage(
        widget.peerLogin,
        StoredMessage(inner.messageId, caption, true, inner.sentAt, status: 'sending', groupId: groupId),
        accountId: widget.peerAccountId,
      );
    }

    for (var i = 0; i < media.length; i++) {
      final item = media[i];
      final size = await item.file.length();
      if (size > _maxAttachmentSizeBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Файл слишком большой (${_formatFileSize(size)})')),
          );
        }
        continue;
      }

      final messageId = '${DateTime.now().microsecondsSinceEpoch}_$i';
      final fileName = item.file.path.split('/').last;

      await ChatStore.addMessage(
        widget.peerLogin,
        StoredMessage(
          messageId,
          item.isVideo ? '🎬 Видео' : '📷 Фото',
          true,
          DateTime.now().millisecondsSinceEpoch,
          isMedia: true,
          isFile: item.isVideo,
          fileSize: size,
          chunked: size > _streamingThresholdBytes,
          fileName: fileName,
          status: 'sending',
          processingStep: 'В очереди',
          localPreviewPath: item.isVideo ? null : item.file.path,
          groupId: groupId,
        ),
        accountId: widget.peerAccountId,
      );

      queue.add((item: item, messageId: messageId, size: size, fileName: fileName));
    }

    await _loadHistory();

    if (groupId != null) {
      await _sendGroupNetwork(groupId, caption: hasCaption ? caption : null, textMessageId: textMessageId, items: queue);
    } else {
      if (textMessageId != null) {
        await _sendTextNetwork(caption, textMessageId);
      }
      for (final q in queue) {
        await _processQueuedMedia(q.item, q.messageId, q.size, q.fileName);
      }
    }
  }

  /// Шифрует и грузит один файл на сервер, сохраняя прогресс локально —
  /// используется и для одиночной отправки, и для сборки группы.
  Future<Map<String, dynamic>> _uploadAndDescribeMedia(
    PickedMedia item,
    String messageId,
    int size,
    String fileName,
    String token,
    String peerAccountIdForUpload,
  ) async {
    final chunked = size > _streamingThresholdBytes;
    String mediaId;
    String keyBase64;
    String? nonceBase64;
    String? macBase64;

    await ChatStore.updateProcessingStep(widget.peerLogin, messageId, 'Шифрование…');

    if (chunked) {
      final tempDir = await getTemporaryDirectory();
      final encTempFile = File('${tempDir.path}/enc_$messageId.bin');
      final inputPath = item.file.path;
      final outputPath = encTempFile.path;
      final keyPath = '${tempDir.path}/key_$messageId.bin';
      await compute(encryptFileIsolateEntry, {
        'input': inputPath,
        'output': outputPath,
        'key': keyPath,
      });
      final keyBytes = await File(keyPath).readAsBytes();
      try {
        await File(keyPath).delete();
      } catch (_) {}

      await ChatStore.updateProcessingStep(widget.peerLogin, messageId, 'Загрузка на сервер…');
      mediaId = await _apiClient.uploadEncryptedMediaFileWithProgress(
        token,
        encTempFile.path,
        peerAccountIdForUpload,
        onProgress: (_) {},
      );
      try {
        await encTempFile.delete();
      } catch (_) {}
      await MediaCache.writeFromFile(mediaId, item.file);
      keyBase64 = base64Encode(keyBytes);
    } else {
      final bytes = await item.file.readAsBytes();
      final encrypted = await encryptFileBytes(bytes);
      await ChatStore.updateProcessingStep(widget.peerLogin, messageId, 'Загрузка на сервер…');
      mediaId = await _apiClient.uploadEncryptedMediaWithProgress(
        token,
        encrypted.ciphertext,
        peerAccountIdForUpload,
        onProgress: (_) {},
      );
      await MediaCache.write(mediaId, bytes);
      keyBase64 = base64Encode(encrypted.key);
      nonceBase64 = base64Encode(encrypted.nonce);
      macBase64 = base64Encode(encrypted.mac);
    }

    await ChatStore.updateMediaInfo(
      widget.peerLogin, messageId,
      mediaId: mediaId, keyBase64: keyBase64, nonceBase64: nonceBase64, macBase64: macBase64,
    );

    return {
      'message_id': messageId,
      'media_id': mediaId,
      'key': keyBase64,
      'nonce': nonceBase64,
      'mac': macBase64,
      'file_name': fileName,
      'is_file': item.isVideo,
      'file_size': size,
      'chunked': chunked,
    };
  }

  Future<void> _processQueuedMedia(PickedMedia item, String messageId, int size, String fileName) async {
    try {
      await SendLock.run(widget.peerLogin, () async {
        final token = await Session.getToken();
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final peerAccountIdForUpload =
            await PeerAccountStore.get(_currentPeerDeviceId) ?? widget.peerAccountId;

        final desc = await _uploadAndDescribeMedia(item, messageId, size, fileName, token!, peerAccountIdForUpload);

        await ChatStore.updateProcessingStep(widget.peerLogin, messageId, 'Согласование с собеседником…');

        final inner = InnerMessage.media(
          messageId: messageId,
          mediaId: desc['media_id'] as String,
          keyBase64: desc['key'] as String,
          nonceBase64: desc['nonce'] as String?,
          macBase64: desc['mac'] as String?,
          fileName: fileName,
          isFile: item.isVideo,
          fileSize: size,
          chunked: desc['chunked'] as bool,
        );

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);
        final encryptedEnvelope = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encryptedEnvelope,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        await ChatStore.updateProcessingStep(widget.peerLogin, messageId, 'Отправка…');
        final status = await WebSocketService.instance.sendEnvelope(_currentPeerDeviceId, envelope, messageId);
        await ChatStore.updateMessageStatus(widget.peerLogin, messageId, status);
      });
    } catch (e, stackTrace) {
      debugPrint('Ошибка отправки медиа $messageId: $e\n$stackTrace');
      await ChatStore.updateMessageStatus(widget.peerLogin, messageId, 'failed');
    } finally {
      await _loadHistory();
    }
  }

  /// Грузит все файлы группы на сервер, затем отправляет ОДИН зашифрованный
  /// конверт со ссылками на все файлы (+ подпись) — собеседник получает
  /// всю группу разом, а не по одному сообщению по мере загрузки.
  Future<void> _sendGroupNetwork(
    String groupId, {
    String? caption,
    String? textMessageId,
    required List<({PickedMedia item, String messageId, int size, String fileName})> items,
  }) async {
    try {
      await SendLock.run(widget.peerLogin, () async {
        final token = await Session.getToken();
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final peerAccountIdForUpload =
            await PeerAccountStore.get(_currentPeerDeviceId) ?? widget.peerAccountId;

        final files = <Map<String, dynamic>>[];
        for (final q in items) {
          files.add(await _uploadAndDescribeMedia(q.item, q.messageId, q.size, q.fileName, token!, peerAccountIdForUpload));
        }

        for (final q in items) {
          await ChatStore.updateProcessingStep(widget.peerLogin, q.messageId, 'Согласование с собеседником…');
        }

        final inner = InnerMessage.mediaGroup(
          groupId: groupId,
          caption: caption,
          textMessageId: textMessageId,
          files: files,
        );

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);
        final encryptedEnvelope = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encryptedEnvelope,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        for (final q in items) {
          await ChatStore.updateProcessingStep(widget.peerLogin, q.messageId, 'Отправка…');
        }
        final status = await WebSocketService.instance.sendEnvelope(_currentPeerDeviceId, envelope, inner.messageId);

        if (textMessageId != null) {
          await ChatStore.updateMessageStatus(widget.peerLogin, textMessageId, status);
        }
        for (final q in items) {
          await ChatStore.updateMessageStatus(widget.peerLogin, q.messageId, status);
        }
      });
    } catch (e, stackTrace) {
      debugPrint('Ошибка отправки группы: $e\n$stackTrace');
      if (textMessageId != null) {
        await ChatStore.updateMessageStatus(widget.peerLogin, textMessageId, 'failed');
      }
      for (final q in items) {
        await ChatStore.updateMessageStatus(widget.peerLogin, q.messageId, 'failed');
      }
    } finally {
      await _loadHistory();
    }
  }

  Future<Uint8List> _loadAndCacheMedia(StoredMessage msg) async {
    final cached = await MediaCache.read(msg.mediaId!);
    if (cached != null) return cached;

    final token = await Session.getToken();
    final ciphertext = await _apiClient.downloadEncryptedMedia(token!, msg.mediaId!);
    final plainBytes = await decryptFileBytes(
      key: base64Decode(msg.mediaKeyBase64!),
      nonce: base64Decode(msg.mediaNonceBase64!),
      mac: base64Decode(msg.mediaMacBase64!),
      ciphertext: ciphertext,
    );
    await MediaCache.write(msg.mediaId!, plainBytes);
    return plainBytes;
  }

  Future<void> _downloadAndDecryptChunked(StoredMessage msg) async {
    final token = await Session.getToken();
    final tempDir = await getTemporaryDirectory();
    final cipherTempFile = File('${tempDir.path}/dl_${msg.mediaId}.enc');

    await _apiClient.downloadEncryptedMediaToFile(token!, msg.mediaId!, cipherTempFile);

    final destFile = await MediaCache.fileFor(msg.mediaId!);
    await StreamingFileCipher.decryptFileToFile(
      inputFile: cipherTempFile,
      outputFile: destFile,
      keyBytes: base64Decode(msg.mediaKeyBase64!),
    );

    try {
      await cipherTempFile.delete();
    } catch (_) {}
  }

  Future<void> _openFile(StoredMessage msg) async {
    try {
      File sourceFile;

      if (msg.chunked) {
        if (!(await MediaCache.exists(msg.mediaId!))) {
          await _downloadAndDecryptChunked(msg);
        }
        sourceFile = await MediaCache.fileFor(msg.mediaId!);
      } else {
        final bytes = await _loadAndCacheMedia(msg);
        final tempDir = await getTemporaryDirectory();
        sourceFile = File('${tempDir.path}/tmp_${msg.mediaId}');
        await sourceFile.writeAsBytes(bytes);
      }

      final tempDir = await getTemporaryDirectory();
      final namedFile = File('${tempDir.path}/${msg.fileName ?? 'file'}');
      await sourceFile.copy(namedFile.path);

      final result = await OpenFile.open(namedFile.path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: ${result.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: $e')),
        );
      }
    }
  }

  Widget _buildAttachmentBubble(StoredMessage msg, {double size = 220}) {
    if (msg.isMine && (msg.status == 'sending' || msg.status == 'failed')) {
      if (msg.status == 'failed') {
        return Stack(
          children: [
            if (msg.localPreviewPath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Opacity(
                    opacity: 0.5,
                    child: Image.file(File(msg.localPreviewPath!), fit: BoxFit.cover),
                  ),
                ),
              )
            else
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
              ),
            const Center(
              child: Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            ),
          ],
        );
      }

      return Stack(
        children: [
          if (msg.localPreviewPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: size,
                height: size,
                child: Image.file(File(msg.localPreviewPath!), fit: BoxFit.cover),
              ),
            )
          else
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
              alignment: Alignment.center,
              child: const Icon(Icons.insert_drive_file, color: Colors.white70, size: 40),
            ),
          if (msg.processingStep != null && size >= 150)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                  ),
                  color: Colors.black54,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      msg.processingStep!,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else if (msg.processingStep != null)
            const Positioned(
              right: 4,
              bottom: 4,
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            ),
        ],
      );
    }

    final isLarge = msg.fileSize >= _autoDownloadLimitBytes;

    if (!isLarge || msg.isMine) {
      return msg.isFile ? _clickableFileRow(msg, size: size) : _photoPreview(msg, size: size);
    }

    final existsFuture = _existsChecks.putIfAbsent(
      msg.mediaId!,
      () => MediaCache.exists(msg.mediaId!),
    );

    return FutureBuilder<bool>(
      future: existsFuture,
      builder: (context, existsSnapshot) {
        if (existsSnapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 40,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final alreadyDownloaded = existsSnapshot.data == true;
        if (alreadyDownloaded) {
          return msg.isFile ? _clickableFileRow(msg, size: size) : _photoPreview(msg, size: size);
        }

        return _downloadPromptRow(msg);
      },
    );
  }

  Widget _downloadPromptRow(StoredMessage msg) {
    if (msg.chunked) {
      final downloading = _chunkedDownloads.containsKey(msg.mediaId);
      return InkWell(
        onTap: downloading
            ? null
            : () {
                setState(() {
                  _existsChecks.remove(msg.mediaId!);
                  _chunkedDownloads[msg.mediaId!] = _downloadAndDecryptChunked(msg);
                });
              },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (downloading)
              FutureBuilder<void>(
                future: _chunkedDownloads[msg.mediaId!],
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    );
                  }
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                  return const Icon(Icons.insert_drive_file, color: Colors.white, size: 28);
                },
              )
            else
              const Icon(Icons.download, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    msg.fileName ?? msg.text,
                    style: const TextStyle(color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatFileSize(msg.fileSize),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final isDownloading = _mediaFutures.containsKey(msg.mediaId);

    return InkWell(
      onTap: isDownloading
          ? null
          : () {
              setState(() {
                _existsChecks.remove(msg.mediaId!);
                _mediaFutures[msg.mediaId!] = _loadAndCacheMedia(msg);
              });
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDownloading)
            FutureBuilder<Uint8List>(
              future: _mediaFutures[msg.mediaId!],
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
                return Icon(
                  msg.isFile ? Icons.insert_drive_file : Icons.image,
                  color: Colors.white,
                  size: 28,
                );
              },
            )
          else
            const Icon(Icons.download, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  msg.isFile ? (msg.fileName ?? msg.text) : '📷 Фото',
                  style: const TextStyle(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatFileSize(msg.fileSize),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _clickableFileRow(StoredMessage msg, {double size = 220}) {
    if (size < 200) {
      return InkWell(
        onTap: () => _openFile(msg),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
          alignment: Alignment.center,
          child: const Icon(Icons.insert_drive_file, color: Colors.white70, size: 32),
        ),
      );
    }
    return InkWell(
      onTap: () => _openFile(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              msg.fileName ?? msg.text,
              style: const TextStyle(color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Список всех фото текущего чата (то, что реально может показать
  /// просмотрщик) в порядке появления в чате — используется и для
  /// определения стартового индекса, и как набор страниц для листания.
  List<StoredMessage> _viewablePhotos() => _messages.where((m) => m.isMedia && !m.isFile).toList();

  void _openMediaViewer(StoredMessage msg) {
    final photos = _viewablePhotos();
    final index = photos.indexWhere((m) => m.messageId == msg.messageId);
    if (index == -1) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MediaViewerScreen<StoredMessage>(
          items: photos,
          initialIndex: index,
          resolveBytes: _resolvePhotoBytes,
        ),
      ),
    );
  }

  Widget _photoPreview(StoredMessage msg, {double size = 220}) {
    final double side = size;

    final cached = _resolvedMedia[msg.mediaId!];
    if (cached != null) {
      return GestureDetector(
        onTap: () => _openMediaViewer(msg),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: side,
            height: side,
            child: Image.memory(cached, fit: BoxFit.cover, cacheWidth: (side * 2).round()),
          ),
        ),
      );
    }

    final future = _mediaFutures.putIfAbsent(msg.mediaId!, () => _resolvePhotoBytes(msg));

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: side,
            height: side,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return SizedBox(
            width: side,
            height: side,
            child: const Center(child: Icon(Icons.broken_image, color: Colors.red)),
          );
        }

        _resolvedMedia[msg.mediaId!] = snapshot.data!;

        return GestureDetector(
          onTap: () => _openMediaViewer(msg),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: side,
              height: side,
              child: Image.memory(snapshot.data!, fit: BoxFit.cover, cacheWidth: (side * 2).round()),
            ),
          ),
        );
      },
    );
  }

  Future<Uint8List> _resolvePhotoBytes(StoredMessage msg) async {
    if (msg.chunked) {
      if (!(await MediaCache.exists(msg.mediaId!))) {
        await _downloadAndDecryptChunked(msg);
      }
      final file = await MediaCache.fileFor(msg.mediaId!);
      return file.readAsBytes();
    }
    return _loadAndCacheMedia(msg);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  String _formatCallDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  /// Запись о звонке рендерится отдельным, визуально нейтральным рядом
  /// по центру — не как обычный текстовый/медиа-пузырь — потому что это
  /// не сообщение от одной из сторон, а факт о звонке, который затрагивает
  /// обоих собеседников одинаково.
  Widget _buildCallLogRow(StoredMessage msg) {
    final isOutgoing = msg.callDirection == 'outgoing';
    final isMissedOrNoAnswer = msg.callOutcome == 'missed' || msg.callOutcome == 'no_answer';

    late final IconData icon;
    late final String label;
    switch (msg.callOutcome) {
      case 'answered':
        icon = isOutgoing ? Icons.call_made : Icons.call_received;
        label = 'Звонок · ${_formatCallDuration(msg.callDurationSeconds ?? 0)}';
        break;
      case 'missed':
        icon = Icons.call_missed;
        label = 'Пропущенный звонок';
        break;
      case 'no_answer':
      default:
        icon = Icons.call_made;
        label = 'Абонент не отвечает';
        break;
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isMissedOrNoAnswer ? Colors.redAccent : Colors.white70),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 6),
            Text(formatChatTime(msg.timestamp), style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIconFor(String status) {
    switch (status) {
      case 'failed':
        return const Icon(Icons.error_outline, size: 13, color: Colors.redAccent);
      case 'sending':
      case 'queued':
        return const Icon(Icons.schedule, size: 13, color: Colors.white70);
      default:
        return const Icon(Icons.done, size: 13, color: Colors.lightBlueAccent);
    }
  }

  /// Группирует подряд идущие сообщения с одинаковым непустым groupId —
  /// такие сообщения были отправлены одним действием пользователя
  /// (несколько файлов и/или файлы с общей подписью) и рендерятся как
  /// один визуальный альбом, хотя по факту остаются разными сообщениями.
  List<List<StoredMessage>> _groupedMessages() {
    final result = <List<StoredMessage>>[];
    var i = 0;
    while (i < _messages.length) {
      final groupId = _messages[i].groupId;
      if (groupId == null) {
        result.add([_messages[i]]);
        i++;
        continue;
      }
      final cluster = <StoredMessage>[];
      while (i < _messages.length && _messages[i].groupId == groupId) {
        cluster.add(_messages[i]);
        i++;
      }
      result.add(cluster);
    }
    return result;
  }

  Widget _buildMediaGrid(List<StoredMessage> mediaMsgs) {
    if (mediaMsgs.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _buildAttachmentBubble(mediaMsgs.first, size: 180),
      );
    }
    const spacing = 3.0;
    final columns = mediaMsgs.length >= 3 ? 3 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : columns * 110.0;
        final tileSize = ((availableWidth - spacing * (columns - 1)) / columns).clamp(70.0, 130.0);
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: mediaMsgs
              .map((m) => ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _buildAttachmentBubble(m, size: tileSize),
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _buildGroupBubble(List<StoredMessage> group) {
    final mediaMsgs = group.where((m) => m.isMedia).toList();
    final textMsgs = group.where((m) => !m.isMedia).toList();
    final isMine = group.first.isMine;
    final last = group.reduce((a, b) => a.timestamp >= b.timestamp ? a : b);
    final hasFailed = group.any((m) => m.status == 'failed');
    final hasPending = group.any((m) => m.status == 'sending' || m.status == 'queued');
    final aggregateStatus = hasFailed ? 'failed' : (hasPending ? 'sending' : 'sent');
    final maxWidth = MediaQuery.of(context).size.width * 0.72;

    return KeyedSubtree(
      key: ValueKey(group.first.groupId),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(6),
          constraints: BoxConstraints(maxWidth: maxWidth),
          decoration: BoxDecoration(
            color: isMine ? AppColors.primary : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mediaMsgs.isNotEmpty) _buildMediaGrid(mediaMsgs),
                  if (textMsgs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                      child: Text(textMsgs.first.text, style: const TextStyle(color: Colors.white)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatChatTime(last.timestamp), style: const TextStyle(color: Colors.white70, fontSize: 10)),
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    _buildStatusIconFor(aggregateStatus),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(StoredMessage msg) {
    if (msg.isCallLog) {
      return KeyedSubtree(key: ValueKey(msg.messageId), child: _buildCallLogRow(msg));
    }
    final maxTextWidth = MediaQuery.of(context).size.width * 0.65;
    return KeyedSubtree(
      key: ValueKey(msg.messageId),
      child: Align(
        alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: msg.isMine ? AppColors.primary : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: msg.isMedia
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildAttachmentBubble(msg),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatChatTime(msg.timestamp),
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                        if (msg.isMine) ...[
                          const SizedBox(width: 4),
                          _buildStatusIconFor(msg.status),
                        ],
                      ],
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxTextWidth),
                      child: Text(
                        msg.text,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formatChatTime(msg.timestamp),
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                    if (msg.isMine) ...[
                      const SizedBox(width: 4),
                      _buildStatusIconFor(msg.status),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (ActiveChatTracker.currentPeerLogin == widget.peerLogin) {
      ActiveChatTracker.currentPeerLogin = null;
    }
    if (_scrollController.hasClients) {
      _savedScrollOffsets[widget.peerLogin] = _scrollController.offset;
    }
    _scrollController.removeListener(_handleScroll);
    _textFocusNode.removeListener(_onFocusChange);
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final realInset = MediaQuery.of(context).viewInsets.bottom;
    final keyboardVisible = realInset > 50;

    if (keyboardVisible && realInset > _keyboardHeight + 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _keyboardHeight = realInset);
        KeyboardHeightStore.updateKnownHeight(realInset);
      });
    }

    // Once realInset catches up to our held target — the real keyboard has
    // fully replaced the emoji panel we were holding space for — release the
    // hold and go back to live-tracking realInset directly.
    if (_switchingMode && !_emojiMode && realInset >= _targetReserve - 4) {
      _switchingMode = false;
    }

    // Резерв места либо ЖИВЬЁМ зеркалит настоящую клавиатуру (обычная печать,
    // системный back и т.п. — realInset уже несёт в себе анимацию самой ОС,
    // повторно анимировать поверх неё не нужно и вредно — именно это давало
    // эффект "резинки"/отставания), либо, во время наших СОБСТВЕННЫХ
    // переключений на эмодзи-панель и обратно (когда реальной анимации ОС,
    // на которую можно опереться, нет), держится на зафиксированной высоте.
    final isLiveTracking = !_emojiMode && !_switchingMode;
    final emojiPanelOnlyVisible = !keyboardVisible && _emojiMode;
    final reserved = isLiveTracking ? realInset : _targetReserve;

    return PopScope(
      canPop: !emojiPanelOnlyVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && emojiPanelOnlyVisible) {
          setState(() {
            _emojiMode = false;
            _targetReserve = 0;
          });
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(_isPeerDeleted ? 'Удалённый аккаунт' : widget.peerLogin),
          actions: [
            IconButton(
              icon: const Icon(Icons.call_outlined),
              iconSize: 26,
              padding: const EdgeInsets.all(14),
              constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
              onPressed: _isPeerDeleted ? null : _startCall,
            ),
          ],
        ),
        body: Column(
          children: [
            OngoingCallBanner(peerLogin: widget.peerLogin),
            Expanded(
              child: Builder(builder: (context) {
                final groups = _groupedMessages();
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    return group.length == 1 ? _buildMessageBubble(group.first) : _buildGroupBubble(group);
                  },
                );
              }),
            ),
            SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    children: [
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          emojiPanelOnlyVisible ? Icons.keyboard : Icons.emoji_emotions_outlined,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () {
                          if (emojiPanelOnlyVisible) {
                            // Реальная клавиатура ещё не поднялась — держим
                            // резерв на месте (_switchingMode), пока realInset
                            // органически не догонит цель, иначе между
                            // "спрятали эмодзи" и "клавиатура ещё не встала"
                            // мелькнёт пустота.
                            _switchingMode = true;
                            setState(() => _emojiMode = false);
                            _textFocusNode.requestFocus();
                          } else {
                            _switchingMode = true;
                            _textFocusNode.unfocus();
                            setState(() {
                              _emojiMode = true;
                              _targetReserve = _keyboardHeight;
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          focusNode: _textFocusNode,
                          onTap: () {
                            if (_emojiMode) setState(() => _emojiMode = false);
                          },
                          style: const TextStyle(color: AppColors.textPrimary),
                          decoration: const InputDecoration(
                            hintText: 'Сообщение',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                            hintStyle: TextStyle(color: AppColors.textMuted),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      if (_hasText)
                        IconButton(
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.send, color: AppColors.primary),
                          onPressed: _handleSendPressed,
                        )
                      else ...[
                        IconButton(
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.attach_file, color: AppColors.textMuted),
                          onPressed: _openAttachmentSheet,
                        ),
                        IconButton(
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.mic, color: AppColors.textMuted),
                          onPressed: () {},
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            AnimatedContainer(
              duration: isLiveTracking ? Duration.zero : const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              height: reserved,
              color: AppColors.surface,
              child: reserved > 0
                  ? ClipRect(
                      child: RepaintBoundary(
                        child: FullEmojiPicker(
                          onEmojiSelected: (emoji) {
                            _textController.text += emoji;
                          },
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}