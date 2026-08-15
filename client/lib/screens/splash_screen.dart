import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import '../services/my_avatar_store.dart';
import '../session.dart';
import 'home_placeholder_screen.dart';
import 'welcome_screen.dart';

/// Проверяет не только "есть ли токен локально", но и его валидность на
/// сервере — если вход был выполнен на другом устройстве, старый токен
/// отзывается сервером, и это единственное надёжное место, где мы это
/// заметим и разлогиним старое устройство.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _decideStartScreen();
  }

  Future<void> _decideStartScreen() async {
    final token = await Session.getToken();
    final deviceId = await KeyStore.getStoredDeviceId();

    if (token == null || deviceId == null) {
      _goTo(const WelcomeScreen());
      return;
    }

    final valid = await ApiClient().checkSession(token);
    if (!valid!) {
      await Session.clearToken();
      await KeyStore.clearAll();
      await CallRingPlugin.clearCredentials();
      MyAvatarStore.reset();
      _goTo(const WelcomeScreen());
      return;
    }

    _goTo(const HomePlaceholderScreen());
  }

  void _goTo(Widget screen) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
