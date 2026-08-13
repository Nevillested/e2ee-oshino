import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class DeleteConfirmResult {
  final bool alsoForPeer;
  const DeleteConfirmResult(this.alsoForPeer);
}

Future<DeleteConfirmResult?> showDeleteMessagesDialog(
  BuildContext context, {
  required String peerName,
}) {
  return showDialog<DeleteConfirmResult>(
    context: context,
    builder: (context) => _DeleteMessagesDialog(peerName: peerName),
  );
}

class _DeleteMessagesDialog extends StatefulWidget {
  final String peerName;
  const _DeleteMessagesDialog({required this.peerName});

  @override
  State<_DeleteMessagesDialog> createState() => _DeleteMessagesDialogState();
}

class _DeleteMessagesDialogState extends State<_DeleteMessagesDialog> {
  bool _alsoForPeer = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
      title: const Text(
        'Удалить сообщение?',
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      content: InkWell(
        onTap: () => setState(() => _alsoForPeer = !_alsoForPeer),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: _alsoForPeer,
                  onChanged: (v) => setState(() => _alsoForPeer = v ?? false),
                  activeColor: AppColors.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Также удалить у ${widget.peerName}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Отмена',
            style: TextStyle(color: AppColors.primary, fontSize: 15),
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(DeleteConfirmResult(_alsoForPeer)),
          child: const Text(
            'Удалить',
            style: TextStyle(color: AppColors.primary, fontSize: 15),
          ),
        ),
      ],
    );
  }
}
