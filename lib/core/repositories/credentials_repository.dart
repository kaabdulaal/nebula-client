import 'dart:convert';
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

    if (SecretStore.factoryPayload != 'PLACEHOLDER') {
      final result = _ffi.importRemoteConfig(SecretStore.factoryPayload);
      if (result == 0) {
        return getCredentials();
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
    if (payload != null) {
      try {
        final sanitizedPayload = payload.trim().replaceAll(RegExp(r'\s+'), '');
        final encryptedBytes = base64Decode(sanitizedPayload);
        
        final keyBytes = utf8.encode('nebula_cartridge_2026');
        final decryptedBytes = List<int>.filled(encryptedBytes.length, 0);
        
        for (var i = 0; i < encryptedBytes.length; i++) {
          decryptedBytes[i] = encryptedBytes[i] ^ keyBytes[i % keyBytes.length];
        }

        final jsonStr = utf8.decode(decryptedBytes);
        final data = jsonDecode(jsonStr);

        final apiId = data['telegram_api_id'] ?? data['api_id'];
        final apiHash = data['telegram_api_hash'] ?? data['api_hash'];
        final version = data['telegram_api_version'] ?? data['version'] ?? 0;

        if (apiId != null && apiHash != null) {
          await saveCredentials(
            apiId is int ? apiId : int.parse(apiId.toString()),
            apiHash.toString(),
            version: version is int ? version : int.parse(version.toString()),
          );
          return true;
        }
      } catch (e) {
        print('[Credentials] Dart decryption failed: $e');
      }

      final result = _ffi.importRemoteConfig(payload);
      if (result == 0) {
        return true;
      }
    }
    return false;
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
