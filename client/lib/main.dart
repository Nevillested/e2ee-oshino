import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 3, 7, 20),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Oshinobu',
              style: TextStyle(
                color: Color.fromARGB(255, 144, 170, 255),
                fontSize: 40,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 200),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const LoginScreen()),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 144, 170, 255),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Вход',
                style: TextStyle(
                  color: Color.fromARGB(255, 6, 20, 58),
                  fontSize: 30,
                ),
              ),
            ),
            const SizedBox(height: 50),
            ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 144, 170, 255),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Регистрация',
                style: TextStyle(
                  color: Color.fromARGB(255, 6, 20, 58),
                  fontSize: 30,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _loginController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _totpController = TextEditingController();

  bool _passwordHidden = true;

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double fieldWidth = MediaQuery.of(context).size.width * 0.4;

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 6, 20, 58),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: fieldWidth,
              child: TextField(
                controller: _loginController,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: 'Логин',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: fieldWidth,
                  child: TextField(
                    controller: _passwordController,
                    obscureText: _passwordHidden,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'Пароль',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _passwordHidden ? Icons.visibility_off : Icons.visibility,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _passwordHidden = !_passwordHidden;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: fieldWidth,
              child: TextField(
                controller: _totpController,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: 'Код из аутентификатора',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {},
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 144, 170, 255),
              ),
              child: const Text(
                'Войти',
                style: TextStyle(
                  color: Color.fromARGB(255, 6, 20, 58),
                  fontSize: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}