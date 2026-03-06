import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import '../api/nebula_api.dart';
import '../repositories/credentials_repository.dart';
import '../services/vault_anchor_service.dart';
import '../services/sync_engine.dart';
import '../services/thumbnail_service.dart';
import '../utils/crypto_utils.dart'; 
import '../security/secret_store.dart';
import '../security/security_manager.dart';
import '../../features/upload/upload_orchestrator.dart';
import 'auth_repository.dart';
import 'auth_state.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository();
});

final credentialsRepositoryProvider = Provider<CredentialsRepository>((ref) {
  return CredentialsRepository();
});

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final repo = ref.watch(authRepositoryProvider);
  final credsRepo = ref.watch(credentialsRepositoryProvider);
  return AuthNotifier(repo, credsRepo);
});

class VaultConnectivityException implements Exception {
  final String message;
  VaultConnectivityException(this.message);
  @override
  String toString() => 'VaultConnectivityException: $message';
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthRepository _repository;
  final CredentialsRepository _credsRepository;

  bool _isAnchoring = false;
  bool _isRestoring = false;
  bool _isCloudChecking = false; 
  bool _isDestroying = false;
  bool _discoveryPending = false; 
  DateTime? _lastDiscoveryTimestamp;
  
  Uint8List? _tempMnemonic;
  String? _tempUnlockPassword; 
  
  bool get _isOnboardingLocked => 
    state.status == AuthStateStatus.needsRestore || 
    state.status == AuthStateStatus.needsVaultSetup ||
    state.status == AuthStateStatus.locked ||
    state.status == AuthStateStatus.vaultCorrupted ||
    state.status == AuthStateStatus.syncRequired ||
    (state.status == AuthStateStatus.loading && (_isRestoring || _isAnchoring));

  StreamSubscription? _updateSubscription;

  AuthNotifier(this._repository, this._credsRepository)
      : super(const AuthState.initializing()) {
    _init();
  }

  @override
  void dispose() {
    _updateSubscription?.cancel();
    _repository.dispose();
    NebulaApi.instance.cleanup();
    super.dispose();
  }

  Future<void> _init() async {
    state = const AuthState.initializing().copyWith(status: AuthStateStatus.loading);

    final healthy = await SecretStore.isKeyringHealthy();
    SecurityManager().setKeyringHealth(healthy);
    if (!healthy) {
      print('[Auth] CRITICAL: System Keyring is UNHEALTHY. Forcing stricter cloud validation.');
    }

    SyncEngine().onSyncThreat = (reason) {
      print('[Auth] SYNC THREAT DETECTED: $reason');
      lockVault();
      if (mounted) {
        state = state.copyWith(status: AuthStateStatus.locked, errorMessage: reason);
      }
    };
    final docsDir = await getNebulaDocumentsDirectory();
    final dbFile = File(p.join(docsDir.path, 'nebula.db'));

    if (state.status == AuthStateStatus.ready) {
      print('[Auth] Already ready, skipping init.');
      return;
    }

    state = state.copyWith(status: AuthStateStatus.loading);

    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSeenOnboarding = prefs.getBool('has_seen_onboarding') ?? false;
      if (!hasSeenOnboarding) {
        print('[Auth] First launch detected (has_seen_onboarding=false). Forcing INITIAL state.');
        if (mounted) {
          state = const AuthState.initial();
        }
        return;
      }
      var creds = await _credsRepository.getCredentials();
      if (creds == null) {
        await _credsRepository.syncCredentials();
        creds = await _credsRepository.getCredentials();
      }

      if (creds == null) {
        if (dbFile.existsSync()) {
          print('[Auth] Graceful offline init. DB exists but no credentials.');
          if (mounted) {
            state = const AuthState.locked(
              errorMessage: 'Offline Mode - Limited Connectivity',
            );
          }
          return;
        }

        print('[Auth] No credentials found and no local DB. Yielding error or initial.');
        if (mounted) {
          state = const AuthState.initial();
        }
        return;
      }

      await _startTDLib(creds, docsDir.path);
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
            status: AuthStateStatus.error, errorMessage: 'Init failed: $e');
      }
    }
  }

  Future<void> _startTDLib(TelegramCredentials creds, String docsDirPath) async {
    final dbPath = p.join(docsDirPath, 'nebula_tdlib');

    // Native Resource Guard: Ensure TDLib directory is not locked by a previous process.
    final tdlibDir = Directory(dbPath);
    if (tdlibDir.existsSync()) {
      final lockFile = File(p.join(dbPath, 'td.binlog.lock'));
      if (lockFile.existsSync()) {
        print('[Auth] WARNING: TDLib lock file detected. Waiting for release...');
        for (int i = 0; i < 5; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!lockFile.existsSync()) {
            print('[Auth] TDLib lock released after ${(i + 1) * 500}ms.');
            break;
          }
          if (i == 4) {
            print('[Auth] TDLib lock persisted after 2.5s. Forcing removal.');
            try { lockFile.deleteSync(); } catch (_) {}
          }
        }
      }
    }

    try {
      await _repository.initTelegram(creds.apiId, creds.apiHash, dbPath);
    } catch (e) {
      throw Exception('FFI initTelegram Native Crash: $e');
    }

    await _updateSubscription?.cancel();
    _updateSubscription = _repository.updates.listen((update) {
      if (!mounted) return;

      final type = update['@type'];
      if (type == 'updateAuthorizationState') {
        _handleAuthState(update['authorization_state']);
      } else if (type == 'error') {
        final message = update['message'] as String? ?? '';
        print('[Auth] TDLib error received: $message');

        final isSyncError = message.contains('SUPERGROUP_ID_INVALID') || 
                            message.contains('Supergroup not found') || 
                            message.contains('chat not found');

        if (state.status == AuthStateStatus.ready || isSyncError) {
          print('[Auth] Swallowing background error: $message');
          return;
        }

        final currentStatus =
            _mapTypeToStatus(_repository.currentAuthState?['@type']);
        state = state.copyWith(
          status: currentStatus,
          errorMessage: message.isEmpty ? 'Unknown Error' : message,
        );
      }
    });

    final currentState = _repository.currentAuthState;
    if (currentState != null) {
      _handleAuthState(currentState);
    } else {
      _repository.requestAuthState();
    }
  }

  AuthStateStatus _mapTypeToStatus(String? type) {
    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        return AuthStateStatus.initializing;
      case 'authorizationStateWaitPhoneNumber':
        return AuthStateStatus.waitingForPhone;
      case 'authorizationStateWaitCode':
        return AuthStateStatus.waitingForCode;
      case 'authorizationStateWaitPassword':
        return AuthStateStatus.waitingForPassword;
      case 'authorizationStateWaitOtherDeviceConfirmation':
        return AuthStateStatus.waitingForOtherDevice;
      case 'authorizationStateReady':
        return AuthStateStatus.ready;
      case 'authorizationStateLoggingOut':
        return AuthStateStatus.initial;
      case 'authorizationStateClosed':
        return AuthStateStatus.error;
      default:
        return state.status;
    }
  }

  Future<void> _handleAuthState(Map<String, dynamic> stateJson) async {
    if (!mounted) return;
    if (_isDestroying) {
      debugPrint('[Auth] IGNORED: _handleAuthState called during destroyAccount. Dropping event.');
      return;
    }

    final type = stateJson['@type'] as String?;

    if (state.status == AuthStateStatus.locked && 
        type != 'authorizationStateReady' && 
        type != 'authorizationStateLoggingOut' && 
        type != 'authorizationStateClosed') {
      print(
          '[Auth] System LOCKED. Ignoring background update: $type');
      return;
    }

    if (state.status == AuthStateStatus.ready && type == 'authorizationStateReady') {
      return;
    }
    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        break;

      case 'authorizationStateWaitPhoneNumber':
        if (state.status == AuthStateStatus.locked) {
          print(
              '[Auth] TDLib needs phone but Vault is LOCKED. Prioritizing Lock Screen.');
          return;
        }
        if (!state.preferPhoneNumber &&
            (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
          state = state.copyWith(
            status: AuthStateStatus.waitingForOtherDevice,
            qrLink: null,
            clearQrLink: true,
            errorMessage: null,
          );
          requestQrCodeAuthentication();
        } else {
          state = state.copyWith(
            status: AuthStateStatus.waitingForPhone,
            errorMessage: null,
          );
        }
        break;

      case 'authorizationStateWaitCode':
        state = state.copyWith(
            status: AuthStateStatus.waitingForCode, errorMessage: null);
        break;

      case 'authorizationStateWaitPassword':
        print('[Auth] OTP Result received: SUCCESS (2FA required)');
        state = state.copyWith(
            status: AuthStateStatus.waitingForPassword, errorMessage: null);
        break;

      case 'authorizationStateWaitOtherDeviceConfirmation':
        state = state.copyWith(
          status: AuthStateStatus.waitingForOtherDevice,
          qrLink: stateJson['link'] as String?,
          errorMessage: null,
        );
        break;

      case 'authorizationStateReady':
        if (state.status == AuthStateStatus.ready && NebulaApi.instance.isInitialized) return;
        if (_isAnchoring || _isCloudChecking || _isRestoring) return;
        
        if (state.status == AuthStateStatus.needsRestore || state.status == AuthStateStatus.needsVaultSetup) {
           print('[Auth] IGNORED background "Ready" update: Waiting for user onboarding/restore.');
           return;
        }

        if (_isOnboardingLocked) {
           print('[Auth] IGNORED background "Ready" update: Onboarding is LOCKED.');
           return;
        }

        try {
        final docsDir = await getNebulaDocumentsDirectory();
        final dbFile = File(p.join(docsDir.path, 'nebula.db'));
        final anchorService = VaultAnchorService();

        final prefs = await SharedPreferences.getInstance();

        if (dbFile.existsSync() || prefs.getInt('vault_channel_id') != null) {
          print('[Auth] Local DB or Cache exists. Yielding Lock Screen instantly.');
          
          final isCoreOpen = NebulaApi.instance.isInitialized;
          
          if (state.status != AuthStateStatus.ready && mounted) {
            if (isCoreOpen) {
              print('[Auth] Transitioning to READY (Core is Open during Reload)');
              state = state.copyWith(
                status: AuthStateStatus.ready,
                errorMessage: null,
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              );
              _initVaultAnchoring();
              SyncEngine().pull();
            } else {
              print('[Auth] Transitioning to LOCKED instantly.');
              state = AuthState.locked(
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              );
            }
          } else if (state.status == AuthStateStatus.ready && _discoveryPending) {
             _initVaultAnchoring();
          }
          break;
        }

        if (Platform.isLinux) {
          print('[Auth] Cold Boot Guard: Waiting 2.5s for Linux TDLib stability...');
          await Future.delayed(const Duration(milliseconds: 2500));
        }

        print('[Auth] No nebula.db found. Scanning cloud for existing vault...');
        state = state.copyWith(status: AuthStateStatus.loading);

        try {
          final vaultExists = await anchorService.detectExistingVault();
          if (!mounted) return;

          if (vaultExists) {
            print('[Auth] Cloud vault detected. Setting needsRestore.');
            _lastDiscoveryTimestamp = DateTime.now();
            state = AuthState.needsRestore(
              sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
            ).copyWith(hasCloudMetadata: true);
          } else {
            print('[Auth] No cloud vault found. Falling back to Setup or Manual Restore.');
            _lastDiscoveryTimestamp = DateTime.now();
            state = AuthState.needsVaultSetup(
              sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
            );
          }
        } catch (e) {
           if (!mounted) return;
           print('[Auth] Cloud discovery failed: $e. Falling back to Setup.');
           state = AuthState.needsVaultSetup(
             sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
           );
         }
       } catch (e) {
         print('[Auth] UNHANDLED ERROR in authorizationStateReady handler: $e');
        if (mounted) {
          state = AuthState.locked(
            sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
          ).copyWith(
            errorMessage: 'Startup error: ${e.toString().substring(0, (e.toString().length > 100 ? 100 : e.toString().length))}',
          );
        }
      }
      break;

      case 'authorizationStateLoggingOut':
      case 'authorizationStateClosed':
        print('[Auth] Session closed (@type: $type).');
        if (state.status == AuthStateStatus.loading || 
            state.status == AuthStateStatus.initializing ||
            state.status == AuthStateStatus.needsVaultSetup ||
            state.status == AuthStateStatus.needsRestore) {
          state = state.copyWith(
            status: AuthStateStatus.error,
            errorMessage: 'Native Session Failure: The underlying TDLib process died unexpectedly during startup or keyring access failed.',
          );
          break;
        }

        if (state.status != AuthStateStatus.initial && state.status != AuthStateStatus.error) {
          state = AuthState.initial(
            sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
          );
        }
        break;

      default:
        break;
    }
  }


  Future<void> _initVaultAnchoring({String? manualMnemonic}) async {
    if (!mounted) return;
    if (_isRestoring) {
      print('[Auth] Anchoring BLOCKED: Restore in progress.');
      return;
    }
    
    String? effectiveMnemonic = manualMnemonic;
    if (effectiveMnemonic == null && _discoveryPending) {
       effectiveMnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
    }

    final hasMnemonic = state.mnemonic != null || _tempMnemonic != null || effectiveMnemonic != null;
    if (!hasMnemonic) {
       effectiveMnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
    }

    if (state.mnemonic == null && _tempMnemonic == null && effectiveMnemonic == null) {
      print('[Auth] No mnemonic source found — skipping anchoring.');
      return;
    }

    if (state.tgUserId == null) {
      try {
        print('[Auth] Fetching TG User ID (Task 9)...');
        final tgUserId = await _repository.getMe();
        if (!mounted) return;
        state = state.copyWith(tgUserId: tgUserId);
        print('[Auth] TG User ID fetched: $tgUserId');
      } catch (e) {
        if (!mounted) return;
        print('[Auth] ERROR fetching TG User ID: $e');
        state = state.copyWith(
          status: AuthStateStatus.error,
          errorMessage: 'Failed to fetch Telegram ID: $e',
        );
        return;
      }
    }

    final mnemonicSeed = state.mnemonic ?? _tempMnemonic;
    final tgUserId = state.tgUserId;
    final password = state.tempPassword ?? _tempUnlockPassword;

    if (tgUserId == null) {
      print('[Auth] Skipping anchoring: tgUserId is null.');
      return;
    }

    try {
      print('[Auth] Starting Vault Anchoring (Atomic Flow)...');
      final anchorService = VaultAnchorService();
      
      final String mnemonicStr;
      if (manualMnemonic != null) {
        mnemonicStr = manualMnemonic;
      } else if (mnemonicSeed != null) {
        mnemonicStr = CryptoUtils.bytesToMnemonic(mnemonicSeed);
      } else if (effectiveMnemonic != null) {
        mnemonicStr = effectiveMnemonic;
      } else {
         print('[Auth] CRITICAL: No mnemonic source resolved for anchoring.');
         return;
      }
      
      final channelId = await anchorService.ensureAnchor(
         mnemonic: mnemonicStr, 
         tgUserId: tgUserId, 
         password: password
      );

      if (channelId == null) {
        print('[Auth] WARNING: Vault Anchoring failed to resolve channelId.');
        return;
      }

      _discoveryPending = false;

      if (!mounted) return;

      state = state.copyWith(
        cloudChannelId: channelId,
        clearMnemonic: true,
        status: AuthStateStatus.ready,
      );
      
      if (mnemonicSeed != null) CryptoUtils.secureClear(mnemonicSeed);
      _tempMnemonic = null;
      _tempUnlockPassword = null;
      
      print('[Auth] Vault Anchoring Complete (Physically Sent & Verified).');
    } catch (e) {
      if (!mounted) return;
      print('[Auth] ERROR during Vault Anchoring: $e');
      state = state.copyWith(
        status: AuthStateStatus.error,
        errorMessage: 'Vault Anchoring failed: $e',
      );
    }
  }


  Future<int> anchorVault({Uint8List? forcedMnemonic}) async {
    if (_isAnchoring) {
      print('[Auth] anchorVault() already in progress — ignoring duplicate call.');
      return -99;
    }

    final password = state.tempPassword;
    var mnemonic = forcedMnemonic ?? state.mnemonic;

    if (forcedMnemonic != null) {
      print('[Auth] anchorVault(): FORCED mnemonic provided (Restore Flow path).');
    }

    if (mnemonic == null && _tempMnemonic != null) {
      print('[Auth] anchorVault(): state.mnemonic missing, using _tempMnemonic.');
      mnemonic = _tempMnemonic;
    }

    if (mnemonic == null) {
       try {
         final storedMnemonic = await SecretStore.readMnemonic();
         if (storedMnemonic != null) {
            print('[Auth] anchorVault(): recovered mnemonic from SecretStore.');
            mnemonic = CryptoUtils.mnemonicToBytes(storedMnemonic);
         }
       } catch (e) {
         print('[Auth] Safe Mode: SecretStore.readMnemonic() failed in anchorVault: $e');
       }
    }

    if (password == null || mnemonic == null) {
      print('[Auth] ERROR: Missing mnemonic/password for anchoring.');
      return -98;
    }

    _isAnchoring = true;
    try {
      if (state.status == AuthStateStatus.needsVaultSetup && forcedMnemonic == null) {
        print('[Auth] New Vault Setup detected. Performing safety WIPE before creation.');
        await _wipeVault(preserveChannel: false);
      }

      final mnemonicStr = CryptoUtils.bytesToMnemonic(mnemonic);
      final result = await NebulaApi.instance.setPassword(mnemonicStr, password);

      if (result == 0) {
        print('[Auth] Vault Created Locally. Now storing Cloud Metadata...');
        state = state.copyWith(masterKey: 'VAULT_CREATED');

        if (SecurityManager().isKeyringHealthy) {
          await SecretStore.saveVaultPassword(password);
        } else {
          print('[Auth] Safe Mode: Bypassing SecretStore vault password save.');
        }

        if (_repository.currentAuthState?['@type'] == 'authorizationStateReady') {
          final anchorService = VaultAnchorService();
          final tgUserId = await _repository.getMe();
          final channelId = await anchorService.ensureAnchor(
            mnemonic: mnemonicStr, 
            tgUserId: tgUserId, 
            password: password,
            isNewVault: true
          );
          
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
          final iv = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
          
          final key = await CryptoUtils.pbkdf2Async(
            password: password,
            salt: salt,
            iterations: 600000,
          );
          
          final encMnemonic = CryptoUtils.aesGcmEncrypt(mnemonic, key, iv);

          if (encMnemonic != null) {
            if (channelId == null) {
              print('[Auth] ERROR: channelId is null during metadata storage.');
            } else {
              await anchorService.cleanupCloudMetadata(channelId);
              final identityHash = anchorService.computeIdentityHash(mnemonicStr, tgUserId);
              await anchorService.setCloudMetadata(
                channelId: channelId,
                epoch: timestamp,
                saltHex: hex.encode(salt),
                ivHex: hex.encode(iv),
                encMnemonicHex: hex.encode(encMnemonic),
                identityHash: identityHash,
              );

              await anchorService.saveLocalAnchor(
                epoch: timestamp,
                identityHash: identityHash,
              );
              
              NebulaApi.instance.setSetting('vault_mnemonic_salt', hex.encode(salt));
              NebulaApi.instance.setSetting('vault_mnemonic_iv', hex.encode(iv));
              NebulaApi.instance.setSetting('vault_mnemonic_enc', hex.encode(encMnemonic));
              
              print('[Auth] Cloud Metadata stored and local anchor updated (with encrypted mnemonic backup).');
            }
          }
        }
        if (SecurityManager().isKeyringHealthy) {
          await SecretStore.saveMnemonic(mnemonicStr);
        } else {
          print('[Auth] Safe Mode: Bypassing SecretStore mnemonic save.');
        }
        final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonicStr);
        SecurityManager().setMasterKey(vmk);
        debugPrint('[Auth] VMK pushed to SecurityManager (Anchor Path)');
        SyncEngine().pull();
      }
      return result;
    } finally {
      _isAnchoring = false;
    }
  }

  Future<int> restoreWithCloudPassword(String password) async {
    print('[Auth] restoreWithCloudPassword() START');
    if (_isRestoring) return -99;
    _isRestoring = true;
    
    state = state.copyWith(status: AuthStateStatus.loading, clearError: true);

    try {
      final anchorService = VaultAnchorService();

      final channelId = await anchorService.findNebulaChannel();
      if (channelId == null) {
        state = state.copyWith(status: AuthStateStatus.needsRestore, errorMessage: 'No Cloud Vault found. Please check manual link.');
        return -1;
      }

      final metadata = await anchorService.getCloudMetadata(channelId);
      if (metadata == null) {
        state = state.copyWith(status: AuthStateStatus.needsRestore, errorMessage: 'No Cloud Password metadata found.');
        return -2;
      }

      final cleanSalt = metadata['Salt']!.split('\n').first.split('#').first.trim();
      final cleanIv = metadata['IV']!.split('\n').first.split('#').first.trim();
      final cleanEnc = metadata['EncMnemonic']!.split('\n').first.split('#').first.trim();

      final salt = Uint8List.fromList(hex.decode(cleanSalt));
      final iv = Uint8List.fromList(hex.decode(cleanIv));
      final encMnemonic = Uint8List.fromList(hex.decode(cleanEnc));

      final key = await CryptoUtils.pbkdf2Async(password: password, salt: salt, iterations: 600000);
      final mnemonicBytes = CryptoUtils.aesGcmDecrypt(encMnemonic, key, iv);
      
      if (mnemonicBytes == null) {
        state = state.copyWith(status: AuthStateStatus.needsRestore, errorMessage: 'Invalid Cloud Password.');
        return 26; 
      }

      final mnemonicStr = CryptoUtils.bytesToMnemonic(Uint8List.fromList(mnemonicBytes));

      print('[Auth] Cloud Mnemonic verified. Executing late-bound WIPE before recovery.');
      await _wipeVault(preserveChannel: true);
      
      final result = await NebulaApi.instance.recoverVault(mnemonicStr, password);
      
      if (result == 0) {
        print('[Auth] Recovery success. Starting blocking Cloud Sync...');
        
        NebulaApi.instance.cleanup(); 
        await Future.delayed(const Duration(milliseconds: 500));
        await NebulaApi.instance.unlockWithPassword(password);
        
        final tgUserId = await _repository.getMe();
        final cloudHash = await anchorService.getHashFromDescription(channelId);
        final identityHash = cloudHash ?? anchorService.computeIdentityHash(mnemonicStr, tgUserId);
        
        await anchorService.saveLocalAnchor(
          epoch: int.tryParse(metadata['Epoch'] ?? '0') ?? 0, 
          identityHash: identityHash
        );

        print('[Auth] SENDING ANCHOR MESSAGE...');
        await anchorService.ensureAnchor(
          mnemonic: mnemonicStr,
          tgUserId: tgUserId,
          password: password,
        );
        print('[Auth] ANCHOR MESSAGE CONFIRMED.');

        final sessionKey = await CryptoUtils.pbkdf2Async(
          password: password,
          salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
          iterations: 100000, 
        );
        SyncEngine().setMasterKey(sessionKey);
        if (SecurityManager().isKeyringHealthy) {
          await SecretStore.saveMnemonic(mnemonicStr);
        } else {
          print('[Auth] Safe Mode: Bypassing SecretStore mnemonic save during restore.');
        }
        NebulaApi.instance.setSetting('vault_mnemonic_salt', cleanSalt);
        NebulaApi.instance.setSetting('vault_mnemonic_iv', cleanIv);
        NebulaApi.instance.setSetting('vault_mnemonic_enc', cleanEnc);
        
        if (mnemonicStr == null || mnemonicStr.isEmpty) {
          throw Exception('CRITICAL: Mnemonic is missing during Restore. Aborting VMK derivation.');
        }

        final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonicStr);
        SecurityManager().setMasterKey(vmk);
        debugPrint('[Auth] VMK pushed to SecurityManager (Restore Path)');
        
        if (mnemonicStr != null) {
          SyncEngine().initializeRealTimeListener();
        }

        state = state.copyWith(
          status: AuthStateStatus.ready, 
          masterKey: 'CLOUD_RESTORED',
          tempPassword: password,
          sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
        );
        
        if (SecurityManager().isKeyringHealthy) {
          await SecretStore.saveVaultPassword(password);
        } else {
          print('[Auth] Safe Mode: Bypassing SecretStore vault password save during restore.');
        }
        
        print('[Auth] STATE SET TO READY. Triggering initial VFS pull...');
        SyncEngine().pull();
      } else {
        state = state.copyWith(status: AuthStateStatus.needsRestore, errorMessage: 'Restore failed (code: $result)');
      }
      
      return result;
    } catch (e) {
      print('[Auth] Restore ERROR: $e');
      state = state.copyWith(status: AuthStateStatus.needsRestore, errorMessage: e.toString());
      return -3;
    } finally {
      _isRestoring = false;
    }
  }


  void sendPhoneNumber(String phone) {
    final cleanPhone = phone.trim();
    if (cleanPhone.isEmpty) {
      state = state.copyWith(
          status: AuthStateStatus.error,
          errorMessage: 'Phone number cannot be empty.');
      return;
    }
    state = state.copyWith(
        status: AuthStateStatus.loading,
        phoneNumber: cleanPhone,
        clearError: true);
    _repository.sendPhoneNumber(cleanPhone);
  }

  void checkCode(String code) {
    state = state.copyWith(status: AuthStateStatus.loading, clearError: true);
    _repository.checkCode(code);
  }

  Future<void> unlockVault(String password) async {
    if (NebulaApi.instance.isInitialized) {
      debugPrint('[Auth] unlockVault: Core already open. Checking VMK status...');
      if (SecurityManager().isReady) {
        debugPrint('[Auth] VMK is already primed. Short-circuiting to READY.');
        if (mounted) state = state.copyWith(status: AuthStateStatus.ready, clearError: true);
        SyncEngine().pull(silent: true);
        return;
      }
      debugPrint('[Auth] VMK IS MISSING despite core open. Proceeding with mnemonic recovery waterfall.');
    }

    state = state.copyWith(status: AuthStateStatus.loading, clearError: true);

    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');
    final dbExists = File(dbPath).existsSync();

    if (!dbExists) {
      print('[Auth] DB file missing during unlock! Checking for cloud vault...');
      final anchorService = VaultAnchorService();
      final vaultExists = await anchorService.detectExistingVault();
      
      if (vaultExists) {
         if (password.isNotEmpty && state.status == AuthStateStatus.needsRestore) {
           print('[Auth] Cloud vault detected and password provided. Executing Cloud Restore...');
           await restoreWithCloudPassword(password);
           return;
         } else {
           print('[Auth] Cloud vault detected. Redirecting to Password Entry for Cloud Restore.');
           if (mounted) {
             state = AuthState.needsRestore(
               sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
             ).copyWith(hasCloudMetadata: true);
           }
           return;
         }
      } else {
         print('[Auth] No cloud vault found. Redirecting to Setup.');
         if (mounted) {
           final ts = DateTime.now().millisecondsSinceEpoch;
           state = AuthState.needsVaultSetup(sessionTimestamp: ts);
         }
         return;
      }
    }

    print('[Auth] Local Vault Unlock attempt...');
    
    if (password.length < 4) {
      state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Password too short.');
      return;
    }

    int result = await NebulaApi.instance.unlockWithPassword(password);

    if (result == 0) {
      if (SecurityManager().isKeyringHealthy) {
        try {
          await SecretStore.saveVaultPassword(password);
        } catch (e) {
          print('[Auth] Warning: Keyring save failed (Linux/Libsecret error?). Proceeding with memory-only session.');
          debugPrint('[Auth] System Keyring Deadlock detected. Security downgraded to DB-only session.');
        }
      } else {
        print('[Auth] Safe Mode: Bypassing Keyring save on Unlock.');
      }

      final sessionKey = await CryptoUtils.pbkdf2Async(
        password: password,
        salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
        iterations: 100000,
      );
      SyncEngine().setMasterKey(sessionKey);

      String? mnemonicStr;
      try {
        mnemonicStr = await SecretStore.readMnemonic();
      } catch (e) {
        print('[Auth] Safe Mode: SecretStore.readMnemonic() failed in unlockVault: $e');
      }
      if (mnemonicStr == null) {
        debugPrint('[Auth] Secure mnemonic missing. Layer 2: Attempting DB-Encrypted fallback...');
        try {
          final sHex = NebulaApi.instance.getSetting('vault_mnemonic_salt');
          final iHex = NebulaApi.instance.getSetting('vault_mnemonic_iv');
          final eHex = NebulaApi.instance.getSetting('vault_mnemonic_enc');
          
          if (sHex != null && iHex != null && eHex != null) {
            final salt = Uint8List.fromList(hex.decode(sHex.trim()));
            final iv = Uint8List.fromList(hex.decode(iHex.trim()));
            final enc = Uint8List.fromList(hex.decode(eHex.trim()));
            
            final key = await CryptoUtils.pbkdf2Async(password: password, salt: salt, iterations: 600000);
            final decBytes = CryptoUtils.aesGcmDecrypt(enc, key, iv);
            
            if (decBytes != null) {
              mnemonicStr = CryptoUtils.bytesToMnemonic(decBytes);
              debugPrint('[Auth] Mnemonic recovered from encrypted DB. Re-seeding SecureStore.');
              if (SecurityManager().isKeyringHealthy) {
                try {
                  await SecretStore.saveMnemonic(mnemonicStr);
                } catch (e) {
                  debugPrint('[Auth] Safe Mode: SecretStore re-seed failed: $e');
                }
              }
            }
          }
        } catch (e) {
          debugPrint('[Auth] DB Recovery FAILED: $e');
        }
      }

      if (mnemonicStr != null && mnemonicStr.isNotEmpty) {
        final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonicStr);
        SecurityManager().setMasterKey(vmk);
        debugPrint('[Auth] VMK pushed to SecurityManager');
        SyncEngine().initializeRealTimeListener();

        print('[Auth] UNLOCK SUCCESS. Entering ready state.');
        state = state.copyWith(
          status: AuthStateStatus.ready, 
          masterKey: 'LOCAL_AUTHENTICATED',
          tempPassword: password, 
          clearError: true,
          sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
        );

        unawaited(_performBackgroundSecurityHandshake(password));
        SyncEngine().pull(silent: true);
      } else {
        debugPrint('[SECURITY] Unlock succeeded but mnemonic decryption failed. Likely Wrong Password.');
        state = state.copyWith(
          status: AuthStateStatus.locked,
          errorMessage: 'Incorrect Password. Please try again.',
        );
        NebulaApi.instance.cleanup(); 
        return;
      }
    } else {
      print('[Auth] Local Vault Unlock FAILED (code: $result). Assume Invalid Password.');
      state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Invalid vault password.');
    }
  }

  void submitTelegram2FAPassword(String password) {
    if (state.status != AuthStateStatus.waitingForPassword) {
      print('[Auth] IGNORED: TDLib password submitted while state is ${state.status}');
      return;
    }
    
    state = state.copyWith(status: AuthStateStatus.loading, clearError: true);
    print('[Auth] Submitting TDLib 2FA Password...');
    _repository.checkPassword(password);
  }

  Future<int> recoverVaultWithMnemonic(String mnemonic, String password) async {
    print('[Auth] recoverVaultWithMnemonic() START');
    if (_isRestoring) return -99;
    _isRestoring = true;

    state = state.copyWith(status: AuthStateStatus.loading, clearError: true);
    
    try {
      print('[Auth] Manual Mnemonic Recovery attempt. Performing pre-recovery WIPE...');
      await _wipeVault();
      
      final result = await NebulaApi.instance.recoverVault(mnemonic, password);
      
      if (result == 0) {
        print('[Auth] Recovery success. Starting blocking Cloud Sync...');
        
        NebulaApi.instance.cleanup(); 
        await Future.delayed(const Duration(milliseconds: 500));
        await NebulaApi.instance.unlockWithPassword(password);
        
        final anchorService = VaultAnchorService();
        final tgUserId = await _repository.getMe();
        final channelId = await anchorService.findNebulaChannel();
        
        if (channelId != null) {
          final cloudHash = await anchorService.getHashFromDescription(channelId);
          final identityHash = cloudHash ?? anchorService.computeIdentityHash(mnemonic, tgUserId);
          
          await anchorService.saveLocalAnchor(identityHash: identityHash);
        }

        print('[Auth] SENDING ANCHOR MESSAGE...');
        await anchorService.ensureAnchor(
          mnemonic: mnemonic,
          tgUserId: tgUserId,
          password: password,
        );
        print('[Auth] ANCHOR MESSAGE CONFIRMED.');

        final sessionKey = await CryptoUtils.pbkdf2Async(
          password: password,
          salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
          iterations: 100000, 
        );
        SyncEngine().setMasterKey(sessionKey);
        
        if (mnemonic == null || mnemonic.isEmpty) {
           throw Exception('CRITICAL: Mnemonic is missing during Recovery. Aborting VMK derivation.');
        }

        final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonic);
        SecurityManager().setMasterKey(vmk);
        SyncEngine().initializeRealTimeListener();

        state = state.copyWith(
          status: AuthStateStatus.ready,
          masterKey: 'MNEMONIC_RECOVERED',
          sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
        );
        
        if (SecurityManager().isKeyringHealthy) {
          await SecretStore.saveVaultPassword(password);
          await SecretStore.saveMnemonic(mnemonic);
        } else {
          print('[Auth] Safe Mode: Bypassing Keyring writes during Manual Recovery.');
        }
        
        try {
          final salt = CryptoUtils.generateRandomBytes(32);
          final iv = CryptoUtils.generateRandomBytes(12);
          final key = await CryptoUtils.pbkdf2Async(password: password, salt: salt, iterations: 600000);
          final enc = CryptoUtils.aesGcmEncrypt(CryptoUtils.mnemonicToBytes(mnemonic), key, iv);
          
          if (enc != null) {
            NebulaApi.instance.setSetting('vault_mnemonic_salt', hex.encode(salt));
            NebulaApi.instance.setSetting('vault_mnemonic_iv', hex.encode(iv));
            NebulaApi.instance.setSetting('vault_mnemonic_enc', hex.encode(enc));
            debugPrint('[Auth] Redundant encrypted mnemonic saved to DB.');
          }
        } catch (e) {
          debugPrint('[Auth] Redundant DB storage FAILED: $e');
        }
        
        print('[Auth] STATE SET TO READY. Triggering initial VFS pull...');
        SyncEngine().pull();
      } else {
        print('[Auth] Mnemonic Recovery FAILED (code: $result).');
        state = state.copyWith(
          status: AuthStateStatus.needsRestore,
          errorMessage: 'Recovery failed (code: $result)',
        );
      }
      return result;
    } catch (e) {
      print('[Auth] Mnemonic Recovery ERROR: $e');
      state = state.copyWith(status: AuthStateStatus.needsRestore, errorMessage: e.toString());
      return -3;
    } finally {
      _isRestoring = false;
    }
  }

  void lockVault() {
    debugPrint('[Auth] Locking vault (preserving DB and Telegram session)...');
    if (NebulaApi.instance.isInitialized) {
      NebulaApi.instance.cleanup();
    }
    ThumbnailService().reset();
    _tempMnemonic = null;
    _tempUnlockPassword = null;
    if (mounted) {
      state = AuthState.locked(
        sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
      );
    }
    debugPrint('[Auth] Vault locked. DB and Telegram session preserved.');
  }

  /// Vault-only nuclear wipe: destroys the cloud channel and local VFS
  /// but PRESERVES the Telegram session. No re-login required.
  Future<void> nukeVaultAndStartOver() async {
    debugPrint('[Auth] nukeVaultAndStartOver: Destroying vault (preserving TDLib session)...');

    if (mounted) {
      state = state.copyWith(status: AuthStateStatus.loading, clearError: true);
    }

    try {
      // 1. Cloud Wipe — find and delete the Telegram channel
      final anchorService = VaultAnchorService();
      final channelId = await anchorService.findNebulaChannel();

      if (channelId != null) {
        debugPrint('[Auth] NUKE: Deleting cloud channel (chatId: $channelId)...');
        try {
          _repository.send({
            '@type': 'deleteChat',
            'chat_id': channelId,
          });
          // Give TDLib a moment to process the deletion
          await Future.delayed(const Duration(milliseconds: 1000));
          debugPrint('[Auth] NUKE: Cloud channel deleted.');
        } catch (e) {
          debugPrint('[Auth] NUKE: Cloud channel deletion failed (non-fatal): $e');
        }
      } else {
        debugPrint('[Auth] NUKE: No cloud channel found. Skipping cloud wipe.');
      }

      // 2. Local VFS Wipe — close DB, delete files, clear caches
      await _wipeVault(preserveChannel: false);

      // 3. Halt and completely clear SyncEngine RAM caches
      SyncEngine().reset();

      // 4. Transition to vault setup — TDLib stays authenticated
      if (mounted) {
        state = AuthState.needsVaultSetup(
          sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
        );
      }
      debugPrint('[Auth] nukeVaultAndStartOver COMPLETE. Ready for new vault creation.');
    } catch (e) {
      debugPrint('[Auth] nukeVaultAndStartOver ERROR: $e');
      if (mounted) {
        state = state.copyWith(
          status: AuthStateStatus.error,
          errorMessage: 'Vault reset failed: $e',
        );
      }
    }
  }

  Future<void> destroyAccount() async {
    debugPrint('[Auth] Destroying account (full wipe)...');
    _isDestroying = true;

    // Safe Guard: Prevent auto-wipe if called within 2s of a successful cloud discovery.
    if (_lastDiscoveryTimestamp != null) {
      final elapsed = DateTime.now().difference(_lastDiscoveryTimestamp!);
      if (elapsed.inSeconds < 2) {
        debugPrint('[Auth] WARNING: destroyAccount() called ${elapsed.inMilliseconds}ms after cloud discovery. Ignoring spurious wipe to prevent data loss.');
        _isDestroying = false;
        return;
      }
    }

    try {
      _updateSubscription?.cancel();
      _updateSubscription = null;
      
      final completer = Completer<void>();
      final tempSub = _repository.updates.listen((update) {
        if (update['@type'] == 'updateAuthorizationState' &&
            update['authorization_state']['@type'] == 'authorizationStateClosed') {
          if (!completer.isCompleted) completer.complete();
        }
      });

      _repository.logOut();
      
      try {
        await completer.future.timeout(const Duration(seconds: 5));
        debugPrint('[Auth] TDLib confirmed closed.');
      } catch (e) {
        debugPrint('[Auth] Note: TDLib closure confirmation timed out (5s). Proceeding anyway.');
      } finally {
        tempSub.cancel();
      }

      // Fully destroy the C++ FFI instance so the next init() starts clean.
      _repository.dispose();
      await Future.delayed(const Duration(milliseconds: 500));

      await _wipeTdlibData();
      await _wipeVault();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_onboarding', false);

      _isDestroying = false;
      if (mounted) {
        state = const AuthState.initial();
      }
    } catch (e) {
      _isDestroying = false;
      debugPrint('[Auth] Destroy account error: $e');
    }
  }

  void cancelLogin() {
    debugPrint('[Auth] Cancelling login (ending TDLib auth session)...');
    _repository.logOut();
    _isAnchoring = false;
    if (mounted) {
      state = const AuthState.initial();
    }
  }

  void triggerRecovery() async {
    print('[Auth] Recovery triggered. Transitioning to Restore screen (Non-destructive).');
    state = AuthState.needsRestore(
      sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void requestQrCodeAuthentication() {
    state = state.copyWith(
      status: AuthStateStatus.waitingForOtherDevice,
      preferPhoneNumber: false,
      clearQrLink: true,
      clearError: true,
    );
    _repository.requestQrCodeAuthentication();
  }


  void switchToPhoneNumber() {
    print('[Auth] Switching to Phone Login — stopping old session first.');
    _updateSubscription?.cancel();
    _updateSubscription = null;
    state = state.copyWith(
      status: AuthStateStatus.loading,
      preferPhoneNumber: true,
      clearQrLink: true,
    );
    _repository.dispose();

    Future.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted) return;
      await _wipeTdlibData();
      if (!mounted) return;
      state = const AuthState.initial().copyWith(
        status: AuthStateStatus.loading,
        preferPhoneNumber: true,
      );
      await _init();
    });
  }

  Future<void> _wipeTdlibData() async {
    try {
      final docsDir = await getNebulaDocumentsDirectory();
      final dbDir = Directory(p.join(docsDir.path, 'nebula_tdlib'));
      for (int i = 0; i < 10; i++) {
        try {
          if (await dbDir.exists()) {
            print('[Auth] Deleting TDLib directory: ${dbDir.path}');
            await dbDir.delete(recursive: true);
          }
          break; // successfully unlocked and deleted
        } catch (e) {
          print('[Auth] TDLib cleanup failed (attempt ${i + 1}): $e');
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    } catch (e) {
      print('[Auth] Note: TDLib cleanup entirely failed: $e');
    }
  }

  Future<void> _wipeVault({bool preserveChannel = false}) async {
    try {
      if (NebulaApi.instance.isInitialized) {
        print('[Auth] WIPE: Closing FFI handle...');
        NebulaApi.instance.cleanup();
      }
      
      final docsDir = await getNebulaDocumentsDirectory();
      final dbFile = File(p.join(docsDir.path, 'nebula.db'));
      if (await dbFile.exists()) {
        print('[Auth] WIPE: Deleting nebula.db');
        await dbFile.delete();
      }
      final walFile = File(p.join(docsDir.path, 'nebula.db-wal'));
      final shmFile = File(p.join(docsDir.path, 'nebula.db-shm'));
      if (await walFile.exists()) await walFile.delete();
      if (await shmFile.exists()) await shmFile.delete();
      
      final prefs = await SharedPreferences.getInstance();
      final keysToRemove = [
        'vault_channel_id',
        'vault_epoch',
        'vault_identity_hash',
        'vault_mnemonic_cached',
        'vault_setup_complete',
        'vault_last_sync',
      ];
      for (final key in keysToRemove) {
        if (preserveChannel && key == 'vault_channel_id') continue;
        await prefs.remove(key);
      }
      print('[Auth] WIPE: Cleared ${keysToRemove.length} SharedPreferences keys.');
      
      final anchorService = VaultAnchorService();
      if (!preserveChannel) {
        await anchorService.clearLocalAnchor();
        try {
          await SecretStore.clearVaultPassword();
          await SecretStore.clearMnemonic();
        } catch (e) {
          print('[Auth] Safe Mode: SecretStore clear failed during wipe: $e');
        }
      }
      
      _tempMnemonic = null;
      _tempUnlockPassword = null;
      
      print('[Auth] WIPE COMPLETE: All local vault state destroyed.');
    } catch (e) {
      print('[Auth] WIPE ERROR: $e');
    }
  }

  Future<void> confirmSync() async {
    print('[Auth] User confirmed sync. Transitioning to Restore Screen (Non-destructive).');
    _isCloudChecking = false;
    _isAnchoring = false;
    _isRestoring = false;

    if (mounted) {
      state = AuthState.needsRestore(
        sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  Future<void> updateDeviceIdentity() async {
    print('[Auth] User requested manual identity update.');
    _isCloudChecking = false;
    
    final anchorService = VaultAnchorService();
    final channelId = await anchorService.findNebulaChannel();
    if (channelId != null) {
      final cloudHash = await anchorService.getHashFromDescription(channelId);
      if (cloudHash != null) {
        await anchorService.saveLocalAnchor(identityHash: cloudHash);
        print('[Auth] Local anchor updated with cloud hash: $cloudHash');
      }
    }
    
    _init();
  }

  void setMasterKey(String hexKey) => state = state.copyWith(masterKey: hexKey);
  void setMnemonic(Uint8List mnemonic) => state = state.copyWith(mnemonic: mnemonic);
  void setTempPassword(String password) => state = state.copyWith(tempPassword: password);
  void setReady() {
    if (!NebulaApi.instance.isInitialized) {
      print('[Auth] BLOCKED: setReady() called but Core is NOT initialized. Refusing false-ready.');
      return;
    }
    state = state.copyWith(
      status: AuthStateStatus.ready,
      sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }
  void clearOnboardingData() => state = state.copyWith(masterKey: null, clearMnemonic: true);
  void forceNewVaultSetup() async {
    print('[Auth] Start Fresh chosen. Transitioning to Setup (Non-destructive).');
    state = const AuthState.needsVaultSetup();
  }
  


  void forceRestoreState() {
    if (state.status == AuthStateStatus.needsRestore) return;
    print('[Auth] Manual Force Sync requested. Transitioning to Restore screen.');
    state = AuthState.needsRestore(
      sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
    ).copyWith(hasCloudMetadata: state.hasCloudMetadata);
  }

  void resetError() {
    state = state.copyWith(clearError: true);
    
    final current = _repository.currentAuthState;
    if (current == null || state.status == AuthStateStatus.error) {
      print('[Auth] Retry pressed and TDLib needs re-init. Re-running _init()...');
      _init();
      return;
    }

    _handleAuthState(current);
  }

  Future<void> submitRekeyPassword(String newPassword) async {
    print('[Auth] Rekey request with new password.');
    final result = await restoreWithCloudPassword(newPassword);
    
    if (result != 0 && mounted) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      state = state.copyWith(
        status: AuthStateStatus.rekeyRequired,
        errorMessage: 'Invalid NEW password. Please try again.',
        sessionTimestamp: ts,
      );
    }
  }

  void resetInitialization() {
    debugPrint('[Auth] Resetting full initialization state...');
    state = const AuthState.initial();
    _isAnchoring = false;
    _isRestoring = false;
    _isCloudChecking = false;
  }

  Future<void> _performBackgroundSecurityHandshake(String password) async {
    print('[Watchdog] Starting Background Security Handshake...');
    final anchorService = VaultAnchorService();
    
    final currentTgState = _repository.currentAuthState;
    if (currentTgState == null || currentTgState['@type'] != 'authorizationStateReady') {
       print('[Watchdog] Telegram not ready. Handshake skipped.');
       return;
    }

    final prefs = await SharedPreferences.getInstance();
    int? channelId = prefs.getInt('vault_channel_id');
    
    if (channelId != null) {
      final isHealthy = await anchorService.checkChannelExistence(channelId);
      if (isHealthy) {
        print('[Watchdog] Fast-track chat accessibility check passed.');
        return;
      }
    }

    channelId = await anchorService.findNebulaChannel();
    if (channelId == null) {
      print('[Watchdog] SECURITY ALERT: Cloud channel missing! Revoking session.');
      if (mounted) {
        lockVault();
        state = state.copyWith(
          status: AuthStateStatus.vaultOrphaned,
          errorMessage: 'Cloud anchor missing. Session revoked for security.',
        );
      }
      return;
    }

    final metadata = await anchorService.getCloudMetadata(channelId);
    if (metadata != null) {
      try {
        final cleanSalt = metadata['Salt']!.split('\n').first.split('#').first.trim();
        final cleanIv = metadata['IV']!.split('\n').first.split('#').first.trim();
        final cleanEnc = metadata['EncMnemonic']!.split('\n').first.split('#').first.trim();
        
        final saltArr = Uint8List.fromList(hex.decode(cleanSalt));
        final ivArr = Uint8List.fromList(hex.decode(cleanIv));
        final encMnemonicArr = Uint8List.fromList(hex.decode(cleanEnc));
        
        final parityKey = await CryptoUtils.pbkdf2Async(password: password, salt: saltArr, iterations: 600000);
        final decContent = CryptoUtils.aesGcmDecrypt(encMnemonicArr, parityKey, ivArr);
        
        if (decContent == null) {
          print('[Watchdog] SECURITY ALERT: Parity Mismatch! Revoking session.');
          if (mounted) {
            lockVault();
            state = state.copyWith(
              status: AuthStateStatus.locked,
              errorMessage: 'Cloud password mismatch. Session revoked.',
            );
          }
          return;
        }
      } catch (e) {
        print('[Watchdog] Verification error: $e');
      }
    }
    
    print('[Watchdog] Background Handshake success.');
  }
  Future<void> completeOnboarding() async {
    print('[Auth] Onboarding complete. Attempting to start TDLib...');
    
    if (state.status == AuthStateStatus.loading) {
       print('[Auth] IGNORED: completeOnboarding is already running.');
       return;
    }

    state = state.copyWith(status: AuthStateStatus.loading);
    
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_onboarding', true);

      var creds = await _credsRepository.getCredentials();
      
      if (creds == null) {
        print('[Auth] No credentials found. Attempting to sync defaults...');
        await _credsRepository.syncCredentials();
        creds = await _credsRepository.getCredentials();
      }

      if (creds == null) {
        print('[Auth] Credentials still missing after sync.');
        state = state.copyWith(
          status: AuthStateStatus.error,
          errorMessage: 'API Credentials could not be loaded. Please check your internet or provide custom keys.',
        );
        return;
      }
      
      final docsDir = await getNebulaDocumentsDirectory();
      await _startTDLib(creds, docsDir.path);
    } catch (e) {
      print('[Auth] completeOnboarding failed: $e');
      state = state.copyWith(
        status: AuthStateStatus.error,
        errorMessage: 'Failed to start TDLib: $e',
      );
    }
  }
}
