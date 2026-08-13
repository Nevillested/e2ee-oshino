import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

OverlayEntry? _currentEntry;

void showLoadingOverlay(BuildContext context, String message) {
  hideLoadingOverlay();
  final overlay = Overlay.of(context);
  _currentEntry = OverlayEntry(
    builder: (context) => Directionality(
      textDirection: TextDirection.ltr,
      child: Positioned.fill(
        child: Container(
          color: Colors.black45,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.normal,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(_currentEntry!);
}

void hideLoadingOverlay() {
  _currentEntry?.remove();
  _currentEntry = null;
}
