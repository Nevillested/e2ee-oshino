import 'package:flutter/material.dart';
import '../crypto/key_store.dart';
import '../session.dart';
import 'home_placeholder_screen.dart';
import 'welcome_screen.dart';

/// Первый экран при запуске приложения. Ничего не показывает пользователю
/// надолго — просто проверяет, есть ли уже сохранённый токен входа, и
/// сразу перенаправляет либо на список чатов, либо на приветственный экран.
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

    if (!mounted) return;

    final nextScreen = (token != null && deviceId != null)
        ? const HomePlaceholderScreen()
        : const WelcomeScreen();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => nextScreen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}