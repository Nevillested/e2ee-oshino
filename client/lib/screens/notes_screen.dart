import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../api/api_client.dart';
import '../crypto/media_cipher.dart';
import '../crypto/streaming_file_cipher.dart';
import '../models/picked_media.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../services/keyboard_height_store.dart';
import '../session.dart';
import '../storage/media_cache.dart';
import '../storage/notes_store.dart';
import '../theme/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/full_emoji_picker.dart';
import '../widgets/media_picker_sheet.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  static const int _autoDownloadLimitBytes = 10 * 1024 * 1024;
  static const int _streamingThresholdBytes = 20 * 1024 * 1024;
  static const int _maxAttachmentSizeBytes = 500 * 1024 * 1024;

  final _textController = TextEditingController();
  final _textFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _apiClient = ApiClient();
  final Map<String, Future<Uint8List>> _mediaFutures = {};
  final Map<String, Uint8List> _resolvedMedia = {};
  final Map<String, Future<bool>> _existsChecks = {};
  final Map<String, Future<void>> _chunkedDownloads = {};

  bool _emojiMode = false;
  double _keyboardHeight = 280;
  double _targetReserve = 0;
  bool _switchingMode = false;
  bool _hasText = false;

  List<NoteMessage> _notes = [];

  @override
  void initState() {
    super.initState();
    _textFocusNode.addListener(_onFocusChange);
    _textController.addListener(_onTextChanged);
    _load();
    NotesStore.changes.listen((_) => _load());
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
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  Future<void> _load() async {
    final notes = await NotesStore.getAll();
    if (!mounted) return;
    setState(() => _notes = notes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _handleSendPressed() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    await NotesStore.addText(text);
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
    final hasCaption = caption.isNotEmpty;
    final groupId = (media.length + (hasCaption ? 1 : 0)) > 1
        ? 'grp_${DateTime.now().microsecondsSinceEpoch}'
        : null;

    if (hasCaption) {
      await NotesStore.addText(caption, groupId: groupId);
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

      final id = '${DateTime.now().microsecondsSinceEpoch}_$i';
      final fileName = item.file.path.split('/').last;
      final chunked = size > _streamingThresholdBytes;

      await NotesStore.addPendingMedia(NoteMessage(
        id,
        item.isVideo ? '🎬 Видео' : '📷 Фото',
        DateTime.now().millisecondsSinceEpoch,
        isMedia: true,
        isFile: item.isVideo,
        fileSize: size,
        chunked: chunked,
        fileName: fileName,
        status: 'sending',
        processingStep: 'В очереди',
        localPreviewPath: item.isVideo ? null : item.file.path,
        groupId: groupId,
      ));

      await _uploadNoteMedia(item, id, size, fileName, chunked);
    }
  }

  Future<void> _uploadNoteMedia(PickedMedia item, String id, int size, String fileName, bool chunked) async {
    try {
      final token = await Session.getToken();
      final myAccountId = await Session.getAccountId();
      if (token == null || myAccountId == null) {
        throw Exception('Не удалось определить аккаунт');
      }

      String mediaId;
      String keyBase64;
      String? nonceBase64;
      String? macBase64;

      await NotesStore.updateProcessingStep(id, 'Шифрование…');

      if (chunked) {
        final tempDir = await getTemporaryDirectory();
        final encTempFile = File('${tempDir.path}/note_enc_$id.bin');
        final inputPath = item.file.path;
        final outputPath = encTempFile.path;
        final keyPath = '${tempDir.path}/note_key_$id.bin';
        await compute(encryptFileIsolateEntry, {
          'input': inputPath,
          'output': outputPath,
          'key': keyPath,
        });
        final keyBytes = await File(keyPath).readAsBytes();
        try {
          await File(keyPath).delete();
        } catch (_) {}

        await NotesStore.updateProcessingStep(id, 'Загрузка на сервер…');
        mediaId = await _apiClient.uploadEncryptedMediaFileWithProgress(
          token, encTempFile.path, myAccountId, onProgress: (_) {},
        );
        try {
          await encTempFile.delete();
        } catch (_) {}
        await MediaCache.writeFromFile(mediaId, item.file);
        keyBase64 = base64Encode(keyBytes);
      } else {
        final bytes = await item.file.readAsBytes();
        final encrypted = await encryptFileBytes(bytes);
        await NotesStore.updateProcessingStep(id, 'Загрузка на сервер…');
        mediaId = await _apiClient.uploadEncryptedMediaWithProgress(
          token, encrypted.ciphertext, myAccountId, onProgress: (_) {},
        );
        await MediaCache.write(mediaId, bytes);
        keyBase64 = base64Encode(encrypted.key);
        nonceBase64 = base64Encode(encrypted.nonce);
        macBase64 = base64Encode(encrypted.mac);
      }

      await NotesStore.updateMediaInfo(id, mediaId: mediaId, keyBase64: keyBase64, nonceBase64: nonceBase64, macBase64: macBase64);
      await NotesStore.updateStatus(id, 'sent');
    } catch (e) {
      await NotesStore.updateStatus(id, 'failed');
    }
  }

  Future<Uint8List> _loadAndCacheMedia(NoteMessage note) async {
    final cached = await MediaCache.read(note.mediaId!);
    if (cached != null) return cached;

    final token = await Session.getToken();
    final ciphertext = await _apiClient.downloadEncryptedMedia(token!, note.mediaId!);
    final plainBytes = await decryptFileBytes(
      key: base64Decode(note.mediaKeyBase64!),
      nonce: base64Decode(note.mediaNonceBase64!),
      mac: base64Decode(note.mediaMacBase64!),
      ciphertext: ciphertext,
    );
    await MediaCache.write(note.mediaId!, plainBytes);
    return plainBytes;
  }

  Future<void> _downloadAndDecryptChunked(NoteMessage note) async {
    final token = await Session.getToken();
    final tempDir = await getTemporaryDirectory();
    final cipherTempFile = File('${tempDir.path}/note_dl_${note.mediaId}.enc');
    await _apiClient.downloadEncryptedMediaToFile(token!, note.mediaId!, cipherTempFile);
    final destFile = await MediaCache.fileFor(note.mediaId!);
    await StreamingFileCipher.decryptFileToFile(
      inputFile: cipherTempFile,
      outputFile: destFile,
      keyBytes: base64Decode(note.mediaKeyBase64!),
    );
    try {
      await cipherTempFile.delete();
    } catch (_) {}
  }

  Future<void> _openFile(NoteMessage note) async {
    try {
      File sourceFile;
      if (note.chunked) {
        if (!(await MediaCache.exists(note.mediaId!))) {
          await _downloadAndDecryptChunked(note);
        }
        sourceFile = await MediaCache.fileFor(note.mediaId!);
      } else {
        final bytes = await _loadAndCacheMedia(note);
        final tempDir = await getTemporaryDirectory();
        sourceFile = File('${tempDir.path}/note_tmp_${note.mediaId}');
        await sourceFile.writeAsBytes(bytes);
      }
      final tempDir = await getTemporaryDirectory();
      final namedFile = File('${tempDir.path}/${note.fileName ?? 'file'}');
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

  Widget _buildAttachmentBubble(NoteMessage note, {double size = 220}) {
    if (note.status == 'sending') {
      return Stack(
        children: [
          if (note.localPreviewPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: size,
                height: size,
                child: Image.file(File(note.localPreviewPath!), fit: BoxFit.cover),
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
          if (note.processingStep != null && size >= 150)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.only(bottomLeft: Radius.circular(14), bottomRight: Radius.circular(14)),
                  color: Colors.black54,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    const SizedBox(width: 6),
                    Text(note.processingStep!, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ],
                ),
              ),
            )
          else if (note.processingStep != null)
            const Positioned(
              right: 4,
              bottom: 4,
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            ),
        ],
      );
    }

    if (note.status == 'failed') {
      return Stack(
        children: [
          if (note.localPreviewPath != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: size,
                height: size,
                child: Opacity(
                  opacity: 0.5,
                  child: Image.file(File(note.localPreviewPath!), fit: BoxFit.cover),
                ),
              ),
            )
          else
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
            ),
          const Center(child: Icon(Icons.error_outline, color: Colors.redAccent, size: 40)),
        ],
      );
    }

    final isLarge = note.fileSize >= _autoDownloadLimitBytes;
    if (!isLarge) {
      return note.isFile ? _clickableFileRow(note, size: size) : _photoPreview(note, size: size);
    }

    final existsFuture = _existsChecks.putIfAbsent(note.mediaId!, () => MediaCache.exists(note.mediaId!));
    return FutureBuilder<bool>(
      future: existsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(height: 40, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        if (snapshot.data == true) {
          return note.isFile ? _clickableFileRow(note, size: size) : _photoPreview(note, size: size);
        }
        return _downloadPromptRow(note);
      },
    );
  }

  Widget _downloadPromptRow(NoteMessage note) {
    if (note.chunked) {
      final downloading = _chunkedDownloads.containsKey(note.mediaId);
      return InkWell(
        onTap: downloading
            ? null
            : () {
                setState(() {
                  _existsChecks.remove(note.mediaId!);
                  _chunkedDownloads[note.mediaId!] = _downloadAndDecryptChunked(note);
                });
              },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (downloading)
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            else
              const Icon(Icons.download, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Text(note.fileName ?? note.text, style: const TextStyle(color: Colors.white)),
          ],
        ),
      );
    }
    final isDownloading = _mediaFutures.containsKey(note.mediaId);
    return InkWell(
      onTap: isDownloading
          ? null
          : () {
              setState(() {
                _existsChecks.remove(note.mediaId!);
                _mediaFutures[note.mediaId!] = _loadAndCacheMedia(note);
              });
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDownloading)
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          else
            const Icon(Icons.download, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          Text(note.isFile ? (note.fileName ?? note.text) : '📷 Фото', style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _clickableFileRow(NoteMessage note, {double size = 220}) {
    if (size < 200) {
      return InkWell(
        onTap: () => _openFile(note),
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
      onTap: () => _openFile(note),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          Text(note.fileName ?? note.text, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  /// Список всех фото в заметках (то, что реально может показать
  /// просмотрщик) в порядке появления — используется и для определения
  /// стартового индекса, и как набор страниц для листания.
  List<NoteMessage> _viewablePhotos() => _notes.where((n) => n.isMedia && !n.isFile).toList();

  void _openMediaViewer(NoteMessage note) {
    final photos = _viewablePhotos();
    final index = photos.indexWhere((n) => n.id == note.id);
    if (index == -1) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MediaViewerScreen<NoteMessage>(
          items: photos,
          initialIndex: index,
          resolveBytes: _resolvePhotoBytes,
        ),
      ),
    );
  }

  Widget _photoPreview(NoteMessage note, {double size = 220}) {
    final double side = size;
    final cached = _resolvedMedia[note.mediaId!];
    if (cached != null) {
      return GestureDetector(
        onTap: () => _openMediaViewer(note),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(width: side, height: side, child: Image.memory(cached, fit: BoxFit.cover, cacheWidth: (side * 2).round())),
        ),
      );
    }
    final future = _mediaFutures.putIfAbsent(note.mediaId!, () => _resolvePhotoBytes(note));
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(width: side, height: side, child: const Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError || snapshot.data == null) {
          return SizedBox(width: side, height: side, child: const Center(child: Icon(Icons.broken_image, color: Colors.red)));
        }
        _resolvedMedia[note.mediaId!] = snapshot.data!;
        return GestureDetector(
          onTap: () => _openMediaViewer(note),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(width: side, height: side, child: Image.memory(snapshot.data!, fit: BoxFit.cover, cacheWidth: (side * 2).round())),
          ),
        );
      },
    );
  }

  Future<Uint8List> _resolvePhotoBytes(NoteMessage note) async {
    if (note.chunked) {
      if (!(await MediaCache.exists(note.mediaId!))) {
        await _downloadAndDecryptChunked(note);
      }
      final file = await MediaCache.fileFor(note.mediaId!);
      return file.readAsBytes();
    }
    return _loadAndCacheMedia(note);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  /// Группирует подряд идущие заметки с одинаковым непустым groupId —
  /// такие заметки были добавлены одним действием (несколько файлов
  /// и/или файлы с общей подписью) и рендерятся как один визуальный
  /// альбом, хотя по факту остаются разными заметками.
  List<List<NoteMessage>> _groupedNotes() {
    final result = <List<NoteMessage>>[];
    var i = 0;
    while (i < _notes.length) {
      final groupId = _notes[i].groupId;
      if (groupId == null) {
        result.add([_notes[i]]);
        i++;
        continue;
      }
      final cluster = <NoteMessage>[];
      while (i < _notes.length && _notes[i].groupId == groupId) {
        cluster.add(_notes[i]);
        i++;
      }
      result.add(cluster);
    }
    return result;
  }

  Widget _buildMediaGrid(List<NoteMessage> mediaNotes) {
    if (mediaNotes.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _buildAttachmentBubble(mediaNotes.first, size: 180),
      );
    }
    const spacing = 3.0;
    final columns = mediaNotes.length >= 3 ? 3 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : columns * 110.0;
        final tileSize = ((availableWidth - spacing * (columns - 1)) / columns).clamp(70.0, 130.0);
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: mediaNotes
              .map((n) => ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _buildAttachmentBubble(n, size: tileSize),
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _buildGroupBubble(List<NoteMessage> group) {
    final mediaNotes = group.where((n) => n.isMedia).toList();
    final textNotes = group.where((n) => !n.isMedia).toList();
    final last = group.reduce((a, b) => a.timestamp >= b.timestamp ? a : b);
    final maxWidth = MediaQuery.of(context).size.width * 0.72;

    return KeyedSubtree(
      key: ValueKey(group.first.groupId),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(6),
          constraints: BoxConstraints(maxWidth: maxWidth),
          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mediaNotes.isNotEmpty) _buildMediaGrid(mediaNotes),
                  if (textNotes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                      child: Text(textNotes.first.text, style: const TextStyle(color: Colors.white)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(formatChatTime(last.timestamp), style: const TextStyle(color: Colors.white70, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoteBubble(NoteMessage note) {
    return KeyedSubtree(
      key: ValueKey(note.id),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(14)),
          child: note.isMedia
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildAttachmentBubble(note),
                    const SizedBox(height: 4),
                    Text(formatChatTime(note.timestamp), style: const TextStyle(color: Colors.white70, fontSize: 10)),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(child: Text(note.text, style: const TextStyle(color: Colors.white))),
                    const SizedBox(width: 6),
                    Text(formatChatTime(note.timestamp), style: const TextStyle(color: Colors.white70, fontSize: 10)),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
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
        appBar: AppBar(title: const Text('Заметки')),
        body: Column(
          children: [
            Expanded(
              child: Builder(builder: (context) {
                final groups = _groupedNotes();
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    return group.length == 1 ? _buildNoteBubble(group.first) : _buildGroupBubble(group);
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
                  decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    children: [
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(emojiPanelOnlyVisible ? Icons.keyboard : Icons.emoji_emotions_outlined, color: AppColors.textMuted),
                        onPressed: () {
                          if (emojiPanelOnlyVisible) {
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
                            hintText: 'Заметка',
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
                        child: FullEmojiPicker(onEmojiSelected: (emoji) => _textController.text += emoji),
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