import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../theme/app_theme.dart';
import 'caption_input_bar.dart';

class MediaPickerSheetResult {
  final List<AssetEntity> items;
  final String caption;
  MediaPickerSheetResult(this.items, this.caption);
}

Future<dynamic> showMediaPickerSheet(BuildContext context) {
  return showModalBottomSheet<dynamic>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _MediaPickerSheetBody(),
  );
}

class _MediaPickerSheetBody extends StatefulWidget {
  const _MediaPickerSheetBody();

  @override
  State<_MediaPickerSheetBody> createState() => _MediaPickerSheetBodyState();
}

class _MediaPickerSheetBodyState extends State<_MediaPickerSheetBody> {
  bool _dragStartedAtTop = false;
  final ScrollController _gridScrollController = ScrollController();
  List<AssetEntity> _assets = [];
  final Map<String, int> _selectedOrder = {};
  CameraController? _liveCamera;
  bool _loading = true;
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};

  @override
  void initState() {
    super.initState();
    _load();
    _initLiveCamera();
  }

  Future<void> _initLiveCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(back, ResolutionPreset.low, enableAudio: false);
      await controller.initialize();
      if (mounted) setState(() => _liveCamera = controller);
    } catch (_) {
      // Нет доступа к камере — плитка останется кликабельной, просто без превью.
    }
  }

  Future<void> _load() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      setState(() => _loading = false);
      return;
    }

    final paths = await PhotoManager.getAssetPathList(type: RequestType.common);
    if (paths.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    final allPath = paths.firstWhere((p) => p.isAll, orElse: () => paths.first);
    final assets = await allPath.getAssetListPaged(page: 0, size: 200);
    assets.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));

    if (mounted) {
      setState(() {
        _assets = assets;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _gridScrollController.dispose();
    _liveCamera?.dispose();
    super.dispose();
  }

  void _toggleSelect(AssetEntity asset) {
    setState(() {
      if (_selectedOrder.containsKey(asset.id)) {
        final removedOrder = _selectedOrder.remove(asset.id)!;
        for (final key in _selectedOrder.keys.toList()) {
          if (_selectedOrder[key]! > removedOrder) {
            _selectedOrder[key] = _selectedOrder[key]! - 1;
          }
        }
      } else {
        _selectedOrder[asset.id] = _selectedOrder.length + 1;
      }
    });
  }

  void _openCameraTile() {
    _liveCamera?.dispose();
    Navigator.pop(context, 'open_camera');
  }

  void _sendSelected(String caption) {
    final ordered = _assets.where((a) => _selectedOrder.containsKey(a.id)).toList()
      ..sort((a, b) => _selectedOrder[a.id]!.compareTo(_selectedOrder[b.id]!));
    Navigator.pop(context, MediaPickerSheetResult(ordered, caption));
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final hasSelection = _selectedOrder.isNotEmpty;

    return Material(
      color: AppColors.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.textMuted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(
              height: screenHeight * 0.5,
              // Stack вместо прежнего "сетка + панель друг под другом в
              // Column" — панель описания теперь ЛЕЖИТ ПОВЕРХ сетки, не
              // сдвигая её вверх при появлении. Сетка остаётся на месте
              // целиком, просто частично перекрывается снизу.
              child: Stack(
                children: [
Positioned.fill(
  child: _loading
      ? const Center(child: CircularProgressIndicator())
      : NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Запоминаем, была ли позиция УЖЕ на самом верху в момент
            // НАЧАЛА этого конкретного жеста — иначе долгий свайп,
            // который просто докручивает список до верха и продолжается
            // дальше в рамках одного и того же движения пальца, тоже
            // закрывал бы шторку, что неверно.
            if (notification is ScrollStartNotification) {
              _dragStartedAtTop = notification.metrics.pixels <= 0;
            } else if (notification is OverscrollNotification) {
              if (_dragStartedAtTop && notification.overscroll < 0) {
                Navigator.pop(context);
              }
            }
            return false;
          },
          child: GridView.builder(
            controller: _gridScrollController,
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 1,
            ),
            itemCount: _assets.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _buildCameraTile();
              return _buildMediaTile(_assets[index - 1]);
            },
          ),
        ),
),
                  if (hasSelection)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: CaptionInputBar(onSend: _sendSelected),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraTile() {
    return InkWell(
      onTap: _openCameraTile,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.black26, width: 0.5)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_liveCamera != null && _liveCamera!.value.isInitialized)
              ClipRect(child: CameraPreview(_liveCamera!))
            else
              Container(color: AppColors.surface),
            const Positioned(
              top: 6,
              right: 6,
              child: Icon(Icons.camera_alt, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaTile(AssetEntity asset) {
    final order = _selectedOrder[asset.id];
    return GestureDetector(
      onTap: () => _toggleSelect(asset),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.black26, width: 0.5)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _thumbnailFutures.putIfAbsent(
                asset.id,
                () => asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
              ),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done || snapshot.data == null) {
                  return Container(color: AppColors.surface);
                }
                return Image.memory(snapshot.data!, fit: BoxFit.cover);
              },
            ),
            if (asset.type == AssetType.video)
              const Positioned(
                bottom: 4,
                left: 4,
                child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => _toggleSelect(asset),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: order != null ? AppColors.primary : Colors.black45,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: order != null
                      ? Text(
                          '$order',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        )
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}