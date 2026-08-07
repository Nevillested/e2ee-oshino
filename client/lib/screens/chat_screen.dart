import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/media_cipher.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../services/message_router.dart';
import '../services/websocket_service.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import '../theme/app_theme.dart';
import '../widgets/encryption_info_badge.dart';
import '../services/send_lock.dart';

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
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _apiClient = ApiClient();
  final Map<String, Future<Uint8List>> _mediaFutures = {};

  String _currentPeerDeviceId = '';
  Map<String, dynamic>? _pendingInitHeader;

  List<StoredMessage> _messages = [];
  bool _isUploadingMedia = false;

  @override
  void initState() {
    super.initState();
    _currentPeerDeviceId = widget.peerDeviceId;
    _loadHistory();
    MessageRouter.updates.listen((peerId) {
      if (peerId == widget.peerAccountId) {
        _loadHistory();
      }
    });
  }

  Future<void> _loadHistory() async {
    final messages = await ChatStore.getMessages(widget.peerAccountId);
    if (!mounted) return;
    setState(() => _messages = messages);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// Перед каждой отправкой уточняем актуальный device_id собеседника —
  /// он мог смениться, если тот вышел из аккаунта и зашёл заново. Слать
  /// на закэшированный при открытии экрана device_id небезопасно: сервер
  /// больше никогда не подключит устройство под старым идентификатором.
  Future<void> _refreshPeerDeviceId() async {
    try {
      final token = await Session.getToken();
      final result = await _apiClient.getDevicesByLogin(token!, widget.peerLogin);
      if (result.devices.isNotEmpty) {
        _currentPeerDeviceId = result.devices.first['device_id'] as String;
      }
    } catch (_) {
      // Не удалось уточнить — используем то, что было.
    }
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

  /// Сообщение появляется в чате СРАЗУ, со статусом "в процессе" — вся
  /// крипто-работа и поход в сеть происходят уже после того, как
  /// пользователь увидел свой текст на экране, а не до.
  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final inner = InnerMessage.text(text);
    _textController.clear();

    await ChatStore.addMessage(
      widget.peerAccountId,
      StoredMessage(inner.messageId, text, true, inner.sentAt, status: 'sending'),
      peerLogin: widget.peerLogin,
    );
    await _loadHistory();

try {
  await SendLock.run(widget.peerAccountId, () async {
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
      ...?initHeader,
    };

    final status = await WebSocketService.instance.sendEnvelope(
      _currentPeerDeviceId,
      envelope,
      inner.messageId,
    );

    await ChatStore.updateMessageStatus(widget.peerAccountId, inner.messageId, status);
  });
} catch (_) {
  await ChatStore.updateMessageStatus(widget.peerAccountId, inner.messageId, 'failed');
} finally {
  await _loadHistory();
}
  }

Future<void> _sendImage() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть галерею: $e')),
      );
      return;
    }
    if (picked == null) return;

    // Сохраняем в локальную non-nullable константу для корректного приведения типов в Dart
    final file = picked;

    setState(() => _isUploadingMedia = true);
    try {
      await SendLock.run(widget.peerAccountId, () async {
        final token = await Session.getToken();
        final myDeviceId = await KeyStore.getStoredDeviceId();
        final state = await _ensureSessionForSending();
        final initHeader = _pendingInitHeader;
        _pendingInitHeader = null;

        final peerAccountIdForUpload =
            await PeerAccountStore.get(_currentPeerDeviceId) ?? widget.peerAccountId;

        // Используем file вместо picked
        final plainBytes = await file.readAsBytes();
        final encrypted = await encryptFileBytes(plainBytes);
        final mediaId = await _apiClient.uploadEncryptedMedia(
          token!,
          encrypted.ciphertext,
          peerAccountIdForUpload,
        );
        await MediaCache.write(mediaId, plainBytes);

        final inner = InnerMessage.media(
          mediaId: mediaId,
          keyBase64: base64Encode(encrypted.key),
          nonceBase64: base64Encode(encrypted.nonce),
          macBase64: base64Encode(encrypted.mac),
          fileName: file.name,
        );

        final next = await state.nextSendingKey();
        await SessionStore.saveState(_currentPeerDeviceId, state);

        final encryptedEnvelope = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encryptedEnvelope,
          ...next.header,
          'sender_device_id': myDeviceId,
          ...?initHeader,
        };

        final status = await WebSocketService.instance.sendEnvelope(
          _currentPeerDeviceId,
          envelope,
          inner.messageId,
        );

        await ChatStore.addMessage(
          widget.peerAccountId,
          StoredMessage(
            inner.messageId,
            '📷 Фото',
            true,
            inner.sentAt,
            isMedia: true,
            mediaId: mediaId,
            mediaKeyBase64: base64Encode(encrypted.key),
            mediaNonceBase64: base64Encode(encrypted.nonce),
            mediaMacBase64: base64Encode(encrypted.mac),
            fileName: file.name,
            status: status,
          ),
          peerLogin: widget.peerLogin,
        );
        await _loadHistory();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить файл: $e')),
        );
      }
    } finally {
      setState(() => _isUploadingMedia = false);
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

  Widget _buildMediaBubble(StoredMessage msg) {
    final future = _mediaFutures.putIfAbsent(msg.mediaId!, () => _loadAndCacheMedia(msg));
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 120,
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return const SizedBox(
            width: 120,
            height: 120,
            child: Center(child: Icon(Icons.broken_image, color: Colors.red)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.memory(snapshot.data!, width: 220, fit: BoxFit.cover),
        );
      },
    );
  }

  /// Статусы, которые честно можем показать: сообщение либо "в процессе"
  /// (шифруется/отправляется или лежит в локальной очереди), либо реально
  /// ушло на сервер, либо отправка провалилась. Статуса "прочитано"
  /// (двойная галочка) пока нет — для него нужен отдельный протокол
  /// подтверждений от собеседника, которого на сервере сейчас не
  /// существует вообще; добавим отдельным шагом позже.
  Widget _buildStatusIcon(StoredMessage msg) {
    switch (msg.status) {
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Colors.redAccent);
      case 'sending':
      case 'queued':
        return const Icon(Icons.schedule, size: 14, color: Colors.white70);
      default:
        return const Icon(Icons.done, size: 14, color: Colors.lightBlueAccent);
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peerLogin),
        actions: [
          IconButton(
            icon: const Icon(Icons.verified_user_outlined),
            onPressed: () => showEncryptionInfoBadge(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return Align(
                  alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: msg.isMine ? AppColors.primary : AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        msg.isMedia
                            ? _buildMediaBubble(msg)
                            : Text(msg.text, style: const TextStyle(color: Colors.white)),
                        if (msg.isMine) ...[
                          const SizedBox(height: 4),
                          _buildStatusIcon(msg),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _isUploadingMedia
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.attach_file, color: AppColors.primary),
                        onPressed: _sendImage,
                      ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: const InputDecoration(hintText: 'Сообщение'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, color: AppColors.primary),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}