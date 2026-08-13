import 'package:flutter/material.dart';
import '../models/pending_attachment.dart';
import '../theme/app_theme.dart';

class AttachmentTray extends StatelessWidget {
  final List<PendingAttachment> attachments;
  final void Function(PendingAttachment) onCancel;

  const AttachmentTray({
    super.key,
    required this.attachments,
    required this.onCancel,
  });

  String _extensionOf(String fileName) {
    final parts = fileName.split('.');
    if (parts.length < 2) return '?';
    return parts.last.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: attachments.length,
        itemBuilder: (context, index) {
          final att = attachments[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              width: 74,
              height: 74,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: att.isImage
                        ? Image.memory(
                            att.bytes,
                            width: 74,
                            height: 74,
                            fit: BoxFit.cover,
                            cacheWidth: 148,
                          )
                        : Container(
                            width: 74,
                            height: 74,
                            color: AppColors.surface,
                            alignment: Alignment.center,
                            child: Text(
                              _extensionOf(att.fileName),
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                  ),
                  if (att.status == AttachmentStatus.uploading)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black45,
                        child: Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 40,
                                height: 40,
                                child: CircularProgressIndicator(
                                  value: att.displayedProgress / 100,
                                  strokeWidth: 3,
                                  backgroundColor: Colors.white24,
                                  color: AppColors.primary,
                                ),
                              ),
                              Text(
                                '${att.displayedProgress.toInt()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (att.status == AttachmentStatus.done)
                    const Positioned(
                      bottom: 2,
                      right: 2,
                      child: Icon(
                        Icons.check_circle,
                        color: Colors.lightGreenAccent,
                        size: 20,
                      ),
                    ),
                  if (att.status == AttachmentStatus.failed)
                    const Positioned(
                      bottom: 2,
                      right: 2,
                      child: Icon(
                        Icons.error,
                        color: Colors.redAccent,
                        size: 20,
                      ),
                    ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => onCancel(att),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(2),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
