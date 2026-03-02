import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nebula_core/nebula_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/remote_config_service.dart';
import '../security/secret_store.dart';

class TelegramCredentials {
  final int apiId;
  final String apiHash;

  TelegramCredentials({required this.apiId, required this.apiHash});
}

class CredentialsRepository {
  final NebulaFFI _ffi = NebulaFFI();
  final RemoteConfigService _remoteConfig = RemoteConfigService();

  static TelegramCredentials? _memoryCredentials;

  Future<bool> hasCredentials() async {
    if (_memoryCredentials != null) return true;
    
    final id = _ffi.getSetting('telegram_api_id');
    final hash = _ffi.getSetting('telegram_api_hash');
    return id != null && hash != null;
  }

  Future<bool> isCustomCredentials() async {
    return _ffi.getSetting('is_custom_credentials') == 'true';
  }

  Future<int> getLocalVersion() async {
    final version = _ffi.getSetting('telegram_api_version');
    return int.tryParse(version ?? '0') ?? 0;
  }

  Future<TelegramCredentials?> getCredentials() async {
    if (_memoryCredentials != null) return _memoryCredentials;

    final idStr = _ffi.getSetting('telegram_api_id');
    final hash = _ffi.getSetting('telegram_api_hash');

    if (idStr != null && hash != null) {
      final id = int.tryParse(idStr);
      if (id != null) {
        return TelegramCredentials(apiId: id, apiHash: hash);
      }
    }

    // Try factory payload via stateless C++ decryption (works without DB)
    if (SecretStore.factoryPayload != 'PLACEHOLDER') {
      final creds = _decryptPayloadViaCpp(SecretStore.factoryPayload);
      if (creds != null) {
        _memoryCredentials = creds;
        return creds;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final cachedId = prefs.getInt('cached_api_id');
    final cachedHash = prefs.getString('cached_api_hash');
    
    if (cachedId != null && cachedHash != null) {
      _memoryCredentials = TelegramCredentials(apiId: cachedId, apiHash: cachedHash);
      return _memoryCredentials;
    }

    return null;
  }

  Future<bool> syncCredentials({bool force = false}) async {
    if (!force && await isCustomCredentials()) {
      return false;
    }

    final payload = await _remoteConfig.fetchRawPayload();
    if (payload == null) return false;

    // Try FFI import first (requires DB to be initialized)
    final result = _ffi.importRemoteConfig(payload);
    if (result == 0 || result == 1) {
      final creds = await getCredentials();
      if (creds != null) {
        await SecretStore.saveCredentials(creds.apiId, creds.apiHash);
      }
      return true;
    }

    // FFI import failed (likely DB not initialized on fresh install).
    // Fallback: use stateless C++ decryption (keeps secrets in native code).
    debugPrint('[Credentials] FFI import failed (code: $result). Using stateless C++ decryption...');
    final creds = _decryptPayloadViaCpp(payload);
    if (creds != null) {
      _memoryCredentials = creds;
      await SecretStore.saveCredentials(creds.apiId, creds.apiHash);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('cached_api_id', creds.apiId);
      await prefs.setString('cached_api_hash', creds.apiHash);

      debugPrint('[Credentials] Stateless C++ decryption succeeded. Credentials cached.');
      return true;
    }

    return false;
  }

  /// Decrypt a cartridge payload using the stateless C++ FFI function.
  /// This works even when the database is not initialized.
  TelegramCredentials? _decryptPayloadViaCpp(String payload) {
    try {
      final jsonStr = _ffi.decryptCartridge(payload);
      if (jsonStr == null) return null;

      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      final apiId = root['api_id'] is int
          ? root['api_id'] as int
          : int.tryParse(root['api_id'].toString());
      final apiHash = root['api_hash'] as String?;

      if (apiId != null && apiHash != null && apiHash.isNotEmpty) {
        debugPrint('[Credentials] C++ cartridge decryption successful. API ID: $apiId');
        return TelegramCredentials(apiId: apiId, apiHash: apiHash);
      }
    } catch (e) {
      debugPrint('[Credentials] C++ cartridge decryption failed: $e');
    }
    return null;
  }

  Future<void> saveCredentials(int apiId, String apiHash,
      {int version = 0, bool isCustom = false}) async {
    _memoryCredentials = TelegramCredentials(apiId: apiId, apiHash: apiHash);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('cached_api_id', apiId);
    await prefs.setString('cached_api_hash', apiHash);

    _ffi.setSetting('telegram_api_id', apiId.toString());
    _ffi.setSetting('telegram_api_hash', apiHash);
    _ffi.setSetting('telegram_api_version', version.toString());
    _ffi.setSetting('is_custom_credentials', isCustom.toString());

    if (isCustom) {
      _ffi.setSetting('manual_api_id', apiId.toString());
      _ffi.setSetting('manual_api_hash', apiHash);
    }
  }
  
  Future<void> persistMemoryCredentials() async {
    if (_memoryCredentials != null) {
      await saveCredentials(_memoryCredentials!.apiId, _memoryCredentials!.apiHash, isCustom: true);
    }
  }

  Future<TelegramCredentials?> getManualCredentials() async {
    final id = _ffi.getSetting('manual_api_id');
    final hash = _ffi.getSetting('manual_api_hash');
    if (id != null && hash != null) {
      final apiId = int.tryParse(id);
      if (apiId != null) {
        return TelegramCredentials(apiId: apiId, apiHash: hash);
      }
    }
    return null;
  }
}
