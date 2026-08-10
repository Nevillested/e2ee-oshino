import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/caption_input_bar.dart';

class CameraCaptureResult {
  final File file;
  final String caption;
  CameraCaptureResult(this.file, this.caption);
}

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _cameraIndex = 0;
  File? _capturedFile;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;
    await _openCamera(_cameraIndex);
  }

  Future<void> _openCamera(int index) async {
    await _controller?.dispose();
    final controller = CameraController(_cameras[index], ResolutionPreset.high, enableAudio: false);
    await controller.initialize();
    if (!mounted) return;
    setState(() {
      _controller = controller;
      _ready = true;
    });
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    setState(() => _ready = false);
    await _openCamera(_cameraIndex);
  }

  Future<void> _capture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final shot = await _controller!.takePicture();
    final tempDir = await getTemporaryDirectory();
    final dest = File('${tempDir.path}/capture_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(shot.path).copy(dest.path);
    setState(() => _capturedFile = dest);
  }

  void _retake() => setState(() => _capturedFile = null);

  void _send(String caption) {
    if (_capturedFile == null) return;
    Navigator.pop(context, CameraCaptureResult(_capturedFile!, caption));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_capturedFile != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: Image.file(_capturedFile!, fit: BoxFit.contain)),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 28),
                        onPressed: _retake,
                      ),
                    ),
                  ],
                ),
              ),
              CaptionInputBar(onSend: _send),
            ],
          ),
        ),
      );
    }

    if (!_ready || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: CameraPreview(_controller!)),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _roundButton(icon: Icons.close, onTap: () => Navigator.pop(context)),
                  InkWell(
                    onTap: _capture,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                    ),
                  ),
                  _roundButton(icon: Icons.cameraswitch, onTap: _flipCamera),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 52,
        height: 52,
        decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}