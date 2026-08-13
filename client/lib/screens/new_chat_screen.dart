import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/swipe_back_page_route.dart';
import 'chat_screen.dart';
import '../storage/peer_account_store.dart';

/// Экран поиска собеседника по логину. Показывает список его устройств.
/// Пока это конечная точка — реальное начало X3DH-обмена с выбранным
/// устройством сделаем отдельным следующим шагом.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _loginController = TextEditingController();
  final _apiClient = ApiClient();

  bool _isLoading = false;
  String? _errorText;
  List<Map<String, dynamic>> _foundDevices = [];

  @override
  void dispose() {
    _loginController.dispose();
    super.dispose();
  }

  String? _peerAccountId;

  // В _NewChatScreenState добавьте поле для хранения peerAccountId:

  Future<void> _search() async {
    final query = _loginController.text.trim();
    final myLogin = await Session.getLogin();

    if (myLogin != null && query == myLogin) {
      final myAccountId = await Session.getAccountId() ?? '';
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        SwipeBackPageRoute(
          builder: (context) => ChatScreen(
            peerDeviceId: '',
            peerAccountId: myAccountId,
            peerLogin: notesPeerLogin,
          ),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
      _foundDevices = [];
    });

    try {
      final token = await Session.getToken();
      final result = await _apiClient.getDevicesByLogin(
        token!,
        _loginController.text.trim(),
      );

      for (final device in result.devices) {
        final deviceId = (device['device_id'] ?? device['deviceId'])
            ?.toString();
        if (deviceId != null && deviceId.isNotEmpty) {
          await PeerAccountStore.save(deviceId, result.accountId);
        }
      }

      setState(() {
        _foundDevices = result.devices;
        _peerAccountId = result.accountId; // Запоминаем accountId
      });
    } catch (e) {
      setState(() {
        _errorText = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Новый чат')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthTextField(
              controller: _loginController,
              hintText: 'Логин собеседника',
            ),
            const SizedBox(height: 14),
            ElevatedButton(
              onPressed: _isLoading ? null : _search,
              child: const Text('Найти'),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 14),
              Text(_errorText!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            Expanded(
              child: ListView.builder(
                itemCount: _foundDevices.length,
                itemBuilder: (context, index) {
                  final device = _foundDevices[index];
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.primary, AppColors.primaryDark],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.person, color: Colors.white),
                      title: Text(
                        _loginController.text.trim(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onTap: () {
                        if (_peerAccountId == null) return;

                        Navigator.pushReplacement(
                          context,
                          SwipeBackPageRoute(
                            builder: (context) => ChatScreen(
                              peerDeviceId: device['device_id'] as String,
                              peerAccountId: _peerAccountId!,
                              peerLogin: _loginController.text.trim(),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
