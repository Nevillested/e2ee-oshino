import 'package:flutter/material.dart';
import '../services/call_service.dart';
import '../theme/app_theme.dart';
import 'call_screen.dart';

class IncomingCallScreen extends StatelessWidget {
  final String peerLogin;
  const IncomingCallScreen({super.key, required this.peerLogin});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const CircleAvatar(radius: 56, child: Icon(Icons.person, size: 56)),
            const SizedBox(height: 20),
            Text(peerLogin, style: const TextStyle(color: AppColors.textPrimary, fontSize: 24)),
            const SizedBox(height: 8),
            const Text('Входящий звонок', style: TextStyle(color: AppColors.textMuted)),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _actionButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    onTap: () {
                      CallService.instance.declineCall();
                      Navigator.pop(context);
                    },
                  ),
                  _actionButton(
                    icon: Icons.call,
                    color: Colors.green,
                    onTap: () async {
                      await CallService.instance.acceptCall();
                      if (context.mounted) {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (context) => CallScreen(peerLogin: peerLogin)),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({required IconData icon, required Color color, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }
}