import 'dart:ui';
import 'package:flutter/material.dart';
import 'account_actions.dart';

class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          height: MediaQuery.of(context).size.height / 15,
          width: double.infinity,
          color: Colors.black.withValues(alpha: 0.12),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => showSettingsSheet(context),
                  child: const Center(
                    child: Icon(Icons.settings, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}