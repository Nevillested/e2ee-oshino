import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

void showEncryptionInfoBadge(BuildContext context) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  Timer? autoHideTimer;

  void remove() {
    autoHideTimer?.cancel();
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (context) => Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: remove,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            top: 60,
            right: 16,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 260),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 8),
                  ],
                ),
                child: Text(
                  tr('encryption.info'),
                  textAlign: TextAlign.right,
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  overlay.insert(entry);
  autoHideTimer = Timer(const Duration(seconds: 4), remove);
}
