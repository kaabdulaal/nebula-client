import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure credential storage backed by flutter_secure_storage.
/// Uses the OS keychain (iOS Keychain / Android EncryptedSharedPreferences).
class SecretStore {
  static const String factoryPayload = String.fromEnvironment(
    'NEBULA_FACTORY_CARTRIDGE',
    defaultValue: 'PLACEHOLDER',
  );

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    lOptions: LinuxOptions(),
  );

  static const _keyApiId = 'nebula_api_id';
  static const _keyApiHash = 'nebula_api_hash';

  /// Store API credentials securely.
  static Future<void> saveCredentials(int apiId, String apiHash) async {
    try {
      await _storage.write(key: _keyApiId, value: apiId.toString());
      await _storage.write(key: _keyApiHash, value: apiHash);
    } catch (e) {
      debugPrint('SecretStore: Secure storage write failed: $e');
      // Fallback for Linux/Non-critical dev environments
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyApiId, apiId.toString());
      await prefs.setString(_keyApiHash, apiHash);
    }
  }

  /// Retrieve stored API credentials.
  static Future<({int? apiId, String? apiHash})> getCredentials() async {
    try {
      final idStr = await _storage.read(key: _keyApiId);
      final hash = await _storage.read(key: _keyApiHash);
      if (idStr != null) {
          return (apiId: int.tryParse(idStr), apiHash: hash);
      }
    } catch (e) {
      debugPrint('SecretStore: Secure storage read failed: $e');
    }

    // Fallback check
    final prefs = await SharedPreferences.getInstance();
    final idStr = prefs.getString(_keyApiId);
    final hash = prefs.getString(_keyApiHash);
    return (apiId: idStr != null ? int.tryParse(idStr) : null, apiHash: hash);
  }

  /// Check if credentials exist.
  static Future<bool> hasCredentials() async {
    try {
      return await _storage.containsKey(key: _keyApiId);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_keyApiId);
    }
  }

  /// Clear stored credentials.
  static Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _keyApiId);
      await _storage.delete(key: _keyApiHash);
    } catch (e) {
       // Ignore
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyApiId);
    await prefs.remove(_keyApiHash);
  }

  /// Generic secure key-value storage.
  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  /// Generic secure key-value retrieval.
  static Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
  }

  // --- Vault Password (for biometric auto-unlock) ---
  static const _keyVaultPassword = 'nebula_vault_password';
  static const _keyBiometricsEnabled = 'nebula_biometrics_enabled';

  /// Save the vault password for biometric-gated retrieval.
  static Future<void> saveVaultPassword(String password) async {
    try {
      await _storage.write(key: _keyVaultPassword, value: password)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely save vault password: $e');
      // STRICT SECURE BOUND: Return silently on Timeout/PlatformException.
      // NEVER write master password to plaintext SharedPreferences.
    }
  }

  /// Read the saved vault password (returns null if not set).
  static Future<String?> readVaultPassword() async {
    try {
      return await _storage.read(key: _keyVaultPassword)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely read vault password: $e');
      return null;
    }
  }

  /// Clear the saved vault password.
  static Future<void> clearVaultPassword() async {
    try {
      await _storage.delete(key: _keyVaultPassword)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely clear vault password: $e');
    }
    // Clean up preferences just in case it was ever leaked previously
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyVaultPassword);
  }

  /// Set whether biometrics is enabled for auto-unlock.
  static Future<void> setBiometricsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometricsEnabled, enabled);
  }

  /// Check if biometrics is enabled.
  static Future<bool> isBiometricsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBiometricsEnabled) ?? false;
  }
}
