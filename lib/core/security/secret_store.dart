import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static Future<void> saveCredentials(int apiId, String apiHash) async {
    try {
      await _storage.write(key: _keyApiId, value: apiId.toString());
      await _storage.write(key: _keyApiHash, value: apiHash);
    } catch (e) {
      debugPrint('SecretStore: Secure storage write failed: $e');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyApiId, apiId.toString());
      await prefs.setString(_keyApiHash, apiHash);
    }
  }

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

    final prefs = await SharedPreferences.getInstance();
    final idStr = prefs.getString(_keyApiId);
    final hash = prefs.getString(_keyApiHash);
    return (apiId: idStr != null ? int.tryParse(idStr) : null, apiHash: hash);
  }

  static Future<bool> hasCredentials() async {
    try {
      return await _storage.containsKey(key: _keyApiId);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_keyApiId);
    }
  }

  static Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _keyApiId);
      await _storage.delete(key: _keyApiHash);
    } catch (e) {
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyApiId);
    await prefs.remove(_keyApiHash);
  }

  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  static Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
  }

  static const _keyVaultPassword = 'nebula_vault_password';
  static const _keyBiometricsEnabled = 'nebula_biometrics_enabled';

  static Future<void> saveVaultPassword(String password) async {
    try {
      await _storage.write(key: _keyVaultPassword, value: password)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely save vault password: $e');
    }
  }

  static Future<String?> readVaultPassword() async {
    try {
      return await _storage.read(key: _keyVaultPassword)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely read vault password: $e');
      return null;
    }
  }

  static Future<void> clearVaultPassword() async {
    try {
      await _storage.delete(key: _keyVaultPassword)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely clear vault password: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyVaultPassword);
  }

  static Future<void> setBiometricsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometricsEnabled, enabled);
  }

  static Future<bool> isBiometricsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBiometricsEnabled) ?? false;
  }

  static const _keyMnemonic = 'nebula_vault_mnemonic';

  static Future<void> saveMnemonic(String mnemonic) async {
    try {
      await _storage.write(key: _keyMnemonic, value: mnemonic)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely save mnemonic: $e');
    }
  }

  static Future<String?> readMnemonic() async {
    try {
      return await _storage.read(key: _keyMnemonic)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('SecretStore: Failed to securely read mnemonic: $e');
      return null;
    }
  }

  static Future<void> clearMnemonic() async {
    try {
      await _storage.delete(key: _keyMnemonic);
    } catch (e) {
      debugPrint('SecretStore: Failed to clear mnemonic: $e');
    }
  }
}
