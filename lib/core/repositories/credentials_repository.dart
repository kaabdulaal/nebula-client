import 'package:nebula_core/nebula_core.dart';
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

  Future<bool> hasCredentials() async {
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

    return null;
  }

  Future<bool> syncCredentials({bool force = false}) async {
    if (!force && await isCustomCredentials()) {
      return false;
    }

    final payload = await _remoteConfig.fetchRawPayload();
    if (payload != null) {
      final result = _ffi.importRemoteConfig(payload);
      if (result == 0) {
        return true;
      }
    }
    return false;
  }

  void saveCredentials(int apiId, String apiHash,
      {int version = 0, bool isCustom = false}) {
    _ffi.setSetting('telegram_api_id', apiId.toString());
    _ffi.setSetting('telegram_api_hash', apiHash);
    _ffi.setSetting('telegram_api_version', version.toString());
    _ffi.setSetting('is_custom_credentials', isCustom.toString());

    if (isCustom) {
      _ffi.setSetting('manual_api_id', apiId.toString());
      _ffi.setSetting('manual_api_hash', apiHash);
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
