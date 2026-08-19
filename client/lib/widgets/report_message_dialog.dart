import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../theme/app_theme.dart';

/// Жалоба на сообщение — переписка E2E-зашифрована, сервер физически не
/// видит текст, поэтому reportedMessageText отправляется добровольно, тем
/// же текстом, что уже виден в собственном пузыре сообщения на экране
/// (см. вызов в chat_screen.dart).
Future<void> showReportMessageDialog(
  BuildContext context, {
  required String reportedDeviceId,
  required String messageText,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ReportMessageDialog(
      reportedDeviceId: reportedDeviceId,
      messageText: messageText,
    ),
  );
}

class _ReportMessageDialog extends StatefulWidget {
  final String reportedDeviceId;
  final String messageText;

  const _ReportMessageDialog({
    required this.reportedDeviceId,
    required this.messageText,
  });

  @override
  State<_ReportMessageDialog> createState() => _ReportMessageDialogState();
}

class _ReportMessageDialogState extends State<_ReportMessageDialog> {
  final _commentController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final token = await Session.getToken();
    if (token == null) return;
    try {
      await ApiClient().reportMessage(
        token,
        widget.reportedDeviceId,
        widget.messageText,
        _commentController.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('report.sent'))));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(
        tr('report.title'),
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: TextField(
        controller: _commentController,
        maxLines: 4,
        style: TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: tr('report.commentHint'),
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        TextButton(
          onPressed: _isLoading ? null : _handleSend,
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  tr('common.send'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
        ),
      ],
    );
  }
}
