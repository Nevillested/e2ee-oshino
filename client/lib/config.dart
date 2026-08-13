class ApiConfig {
  static const String baseUrl = 'https://ee2e.oshino.space';

  static String get wsBaseUrl {
    if (baseUrl.startsWith('https://')) {
      return 'wss://${baseUrl.substring('https://'.length)}';
    }
    return 'ws://${baseUrl.substring('http://'.length)}';
  }
}
