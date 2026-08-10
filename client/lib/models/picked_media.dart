import 'dart:io';

class PickedMedia {
  final File file;
  final bool isVideo;
  PickedMedia({required this.file, this.isVideo = false});
}