class TelegramConfig {
  static const int apiId = int.fromEnvironment('TELEGRAM_API_ID');
  static const String apiHash = String.fromEnvironment('TELEGRAM_API_HASH');

  static bool get isValid => apiId != 0 && apiHash.isNotEmpty;
}
