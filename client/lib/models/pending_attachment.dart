import 'dart:typed_data';

enum AttachmentStatus { uploading, done, failed }

class PendingAttachment {
  final String id;
  final String fileName;
  final Uint8List bytes;
  final bool isImage;
  final bool isFile;
  final int fileSize;
  final String? filePath;

  double progress;
  double displayedProgress;
  AttachmentStatus status;
  bool cancelled;
  bool chunked;

  String? mediaId;
  String? keyBase64;
  String? nonceBase64;
  String? macBase64;

  PendingAttachment({
    required this.id,
    required this.fileName,
    required this.bytes,
    required this.isImage,
    this.isFile = false,
    int? fileSize,
    this.filePath,
    this.progress = 0,
    this.displayedProgress = 0,
    this.status = AttachmentStatus.uploading,
    this.cancelled = false,
    this.chunked = false,
  }) : fileSize = fileSize ?? bytes.length;
}