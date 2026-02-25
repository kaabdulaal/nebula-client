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
import '../utils/crypto_utils.dart'; 
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
  bool _discoveryPending = false; 
  
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

    final docsDir = await getNebulaDocumentsDirectory();
    final dbFile = File(p.join(docsDir.path, 'nebula.db'));

    if (state.status == AuthStateStatus.ready) {
      print('[Auth] Already ready, skipping init.');
      return;
    }

    state = state.copyWith(status: AuthStateStatus.loading);

    try {
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

        if (mounted) {
          state = const AuthState.error(
              'Network connection error. Please check your internet and try again.');
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

    await _repository.initTelegram(creds.apiId, creds.apiHash, dbPath);

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
      case 'authorizationStateClosed':
        return AuthStateStatus.initial;
      default:
        return state.status;
    }
  }

  Future<void> _handleAuthState(Map<String, dynamic> stateJson) async {
    if (!mounted) return;

    if (state.status == AuthStateStatus.locked && stateJson['@type'] != 'authorizationStateReady') {
      print(
          '[Auth] System LOCKED. Ignoring background update: ${stateJson['@type']}');
      return;
    }

    if (state.status == AuthStateStatus.ready && stateJson['@type'] == 'authorizationStateReady') {
      return;
    }

    final type = stateJson['@type'] as String?;

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
        if (state.manualChatId != null) {
          anchorService.setManualChatId(state.manualChatId);
        }

        if (dbFile.existsSync()) {
          print('[Auth] Mandatory Cloud Check (Identity Sync)...');
          _isCloudChecking = true;
          
          try {
            int retries = 0;
            bool checkComplete = false;

            while (retries < 3) {
              try {
                final delay = Duration(seconds: pow(2, retries).toInt());
                if (retries > 0) {
                  print('[Auth] Retrying cloud check in ${delay.inSeconds}s...');
                  await Future.delayed(delay);
                }

                await anchorService.refreshChatList().timeout(const Duration(seconds: 10));
                
                final channelId = await anchorService.findNebulaChannel();
                
                if (channelId == null) {
                  print('[Auth] Cloud Channel not found. Transitioning to Discovery Fallback.');
                  state = AuthState.needsRestore(
                    sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
                  ).copyWith(isDiscoveryFallback: true);
                  checkComplete = true; 
                  break; 
                }

                final cloudMetadata = await anchorService.getCloudMetadata(channelId).timeout(const Duration(seconds: 10));
                final cloudHash = await anchorService.getHashFromDescription(channelId);

                if (cloudMetadata == null || cloudHash == null) {
                  print('[Auth] Metadata missing from cloud. Trusting Local Vault.');
                  checkComplete = true;
                  break;
                }

                final cloudEpoch = int.tryParse(cloudMetadata['Epoch'] ?? '0') ?? 0;
                final localEpoch = await anchorService.getLocalEpoch();
                final localHash = await anchorService.getLocalIdentityHash();

                print('[Auth] Sync Check: Cloud(E:$cloudEpoch, H:$cloudHash) vs Local(E:$localEpoch, H:$localHash)');

                bool identityMismatch = (localHash != null && localHash != cloudHash);
                bool epochMismatch = cloudEpoch > localEpoch;

                if (!identityMismatch && !epochMismatch) {
                   checkComplete = true;
                   break;
                }

                if (identityMismatch && !epochMismatch) {
                  print('[Auth] Identity mismatch but Epoch is safe (Local: $localEpoch, Cloud: $cloudEpoch). Trusting local DB.');
                  identityMismatch = false; 
                }

                if (epochMismatch) {
                  if (identityMismatch) {
                    print('[Auth] SYNC CONFLICT detect: Identity=$identityMismatch, Epoch=$epochMismatch.');
                    state = const AuthState.syncRequired().copyWith(
                      errorMessage: "Vault was updated on another device. Confirm to sync local database.",
                      sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
                    );
                    _isCloudChecking = false;
                    return;
                  } else {
                    print('[Auth] Epoch mismatch but Identity matches perfectly. Silently updating local Epoch to sync with Cloud.');
                    await anchorService.saveLocalAnchor(epoch: cloudEpoch, identityHash: cloudHash);
                  }
                }
                
                checkComplete = true; 
                break;
              } catch (e) {
                retries++;
                print('[Auth] Cloud Check attempt $retries failed: $e');
              }
            }

            if (!checkComplete && mounted) {
              print('[Auth] Cloud Sync SLOW or OFFLINE after 3 retries. Falling back to Lock Screen.');
            }
          } finally {
            _isCloudChecking = false;
          }

          if (!mounted) return;

          final isCoreOpen = NebulaApi.instance.isInitialized;
          
          if (state.status != AuthStateStatus.ready && mounted) {
            if (isCoreOpen) {
              // Derive Session Key for VFS Security Hardening
              final password = state.tempPassword; // Assuming tempPassword holds the unlock password
              if (password != null) {
                final sessionKey = await CryptoUtils.pbkdf2Async(
                  password: password,
                  salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
                  iterations: 100000,
                );
                SyncEngine().setMasterKey(sessionKey);
                final mnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
                if (mnemonic != null) {
                  final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonic);
                  SyncEngine().setMasterKey(vmk);
                  SyncEngine().initializeRealTimeListener();
                }
              }

              print('[Auth] Transitioning to READY (Core is Open)');
              state = state.copyWith(
                status: AuthStateStatus.ready,
                errorMessage: null,
                tempPassword: password, // Keep tempPassword for session key derivation
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              );
              _initVaultAnchoring();
              // Trigger background sync
              SyncEngine().pull();
            } else {
              print('[Auth] Core is CLOSED. Transitioning to LOCKED (Security Guard).');
              state = AuthState.locked(
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              );
            }
          } else if (state.status == AuthStateStatus.ready && _discoveryPending) {
             _initVaultAnchoring();
          }
        } else {
          print('[Auth] No nebula.db found. Checking cloud for existing vault...');
          state = state.copyWith(status: AuthStateStatus.loading);

          try {
            final vaultExists = await anchorService.detectExistingVault();
            if (!mounted) return;

            if (vaultExists || state.manualChatId != null) {
              print('[Auth] Cloud vault detected (or manual ChatID set). Setting needsRestore.');
              state = AuthState.needsRestore(
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              ).copyWith(hasCloudMetadata: vaultExists);
            } else {
              print('[Auth] No cloud vault found. Falling back to Restore Screen (Manual Bridge).');
              state = AuthState.needsRestore(
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              ).copyWith(isDiscoveryFallback: true);
            }
          } catch (e) {
            if (!mounted) return;
            print('[Auth] Cloud vault detection failed: $e. Falling back to Restore Screen (Manual Bridge).');
            state = AuthState.needsRestore(
              sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
            ).copyWith(isDiscoveryFallback: true);
          }
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
        if (state.status != AuthStateStatus.initial &&
            state.status != AuthStateStatus.loading) {
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
      final metadata = await anchorService.getCloudMetadata(channelId);
      
      if (metadata == null && password != null) {
        print('[Auth] Metadata missing on existing anchor. Triggering HEAL...');
        await anchorService.healMetadata(
          channelId: channelId,
          mnemonic: mnemonicStr,
          password: password,
        );
      }

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
       final storedMnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
       if (storedMnemonic != null) {
          print('[Auth] anchorVault(): recovered mnemonic from secure vault.');
          mnemonic = CryptoUtils.mnemonicToBytes(storedMnemonic);
       }
    }

    if (password == null || mnemonic == null) {
      print('[Auth] ERROR: Missing mnemonic/password for anchoring.');
      return -98;
    }

    _isAnchoring = true;
    try {
      final mnemonicStr = CryptoUtils.bytesToMnemonic(mnemonic);
      final result = await NebulaApi.instance.setPassword(mnemonicStr, password);

      if (result == 0) {
        print('[Auth] Vault Created Locally. Now storing Cloud Metadata...');
        state = state.copyWith(masterKey: 'VAULT_CREATED');

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
              print('[Auth] Cloud Metadata stored and local anchor updated.');
            }
          }
        }
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
      if (state.manualChatId != null) {
        anchorService.setManualChatId(state.manualChatId);
      }
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

        // Derive Session Key for VFS Security Hardening
        final sessionKey = await CryptoUtils.pbkdf2Async(
          password: password,
          salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
          iterations: 100000, 
        );
        SyncEngine().setMasterKey(sessionKey);
        final mnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
        if (mnemonic != null) {
          final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonic);
          SyncEngine().setMasterKey(vmk);
          SyncEngine().initializeRealTimeListener();
        }

        state = state.copyWith(
          status: AuthStateStatus.ready, 
          masterKey: 'CLOUD_RESTORED',
          tempPassword: password,
          sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
        );
        
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
      print('[Auth] CRITICAL: unlockVault called while Core is ALREADY OPEN. ABORTING.');
      return;
    }

    state = state.copyWith(status: AuthStateStatus.loading, clearError: true);

    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');
    final dbExists = File(dbPath).existsSync();

    if (!dbExists) {
      print('[Auth] DB file missing during unlock! Redirecting to Restore/Setup.');
      final anchorService = VaultAnchorService();
      final vaultExists = await anchorService.detectExistingVault();
      if (mounted) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        state = vaultExists ? AuthState.needsRestore(sessionTimestamp: ts) : AuthState.needsVaultSetup(sessionTimestamp: ts);
      }
      return;
    }

    print('[Auth] Local Vault Unlock attempt...');
    
    if (password.length < 4) {
      state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Password too short.');
      return;
    }

    int result = await NebulaApi.instance.unlockWithPassword(password);
    
    if (result == 26) {
      print('[Auth] SQLITE_NOTADB detected. Retrying after cooldown...');
      await Future.delayed(const Duration(milliseconds: 500));
      if (!File(dbPath).existsSync()) {
         print('[Auth] DB disappeared during cooldown.');
         state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Vault database missing.');
         return;
      }
      result = await NebulaApi.instance.unlockWithPassword(password);
      
      if (result == 26) {
        final anchorService = VaultAnchorService();
        int? cloudAnchorId;
        
        try {
           cloudAnchorId = await anchorService.findNebulaChannel();
        } catch (e) {
           print('[Auth] Could not verify cloud anchor (Offline/Timeout). Assuming WRONG PASSWORD to prevent accidental wipe.');
           state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Invalid password or connection error.');
           return;
        }

        if (cloudAnchorId == null) {
          if (_repository.currentAuthState == null) {
             print('[Auth] Network is likely down (TDLib uninitialized). Refusing to wipe offline. Assumed Wrong Password.');
             state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Invalid password or connection error.');
             return;
          }

          print('[Auth] UNRECOVERABLE: Local DB is NOTADB and Cloud is Empty. Wiping local state for fresh start.');
          if (File(dbPath).existsSync()) File(dbPath).deleteSync();
          await anchorService.clearLocalAnchor();
          state = const AuthState.initial();
          return;
        } else {
          final metadata = await anchorService.getCloudMetadata(cloudAnchorId);
          if (metadata != null) {
            try {
              final cleanSalt = metadata['Salt']!.split('\n').first.split('#').first.trim();
              final cleanIv = metadata['IV']!.split('\n').first.split('#').first.trim();
              final cleanEnc = metadata['EncMnemonic']!.split('\n').first.split('#').first.trim();

              final salt = Uint8List.fromList(hex.decode(cleanSalt));
              final iv = Uint8List.fromList(hex.decode(cleanIv));
              final encMnemonic = Uint8List.fromList(hex.decode(cleanEnc));
              
              final key = await CryptoUtils.pbkdf2Async(
                password: password,
                salt: salt,
                iterations: 600000,
              );
              
              final dec = CryptoUtils.aesGcmDecrypt(encMnemonic, key, iv);
              if (dec != null) {
                print('[Auth] ZOMBIE DB DETECTED. Correct password but local DB produces NOTADB. Physical wipe & Triggering Restore.');
                NebulaApi.instance.cleanup();
                if (File(dbPath).existsSync()) File(dbPath).deleteSync();
                await anchorService.clearLocalAnchor();
                
                final ts = DateTime.now().millisecondsSinceEpoch;
                state = AuthState.needsRestore(sessionTimestamp: ts);
                return;
              }
            } catch (e) {
              print('[Auth] Failed to verify password against cloud during deadlock: $e');
            }
          }
        }
      }
    }

    if (result == 0) {
      final testQuery = NebulaApi.instance.getSetting('vault_init_sentinel');
      
      if (testQuery == null) {
        print('[Auth] Sentinel "vault_init_sentinel" not found. Testing DB write access...');
        final writeRc = NebulaApi.instance.setSetting('vault_init_sentinel', '1');
        
        if (writeRc == 0) {
          print('[Auth] DB Write Succeeded! Recognized as New/Empty Vault state.');
        } else {
          print('[Auth] CRITICAL: DB Write FAILED ($writeRc). Vault is genuinely corrupted.');
          NebulaApi.instance.cleanup(); 
          
          final anchorService = VaultAnchorService();
          int? cloudAnchorId;
          
          try {
             cloudAnchorId = await anchorService.findNebulaChannel();
          } catch (e) {
             print('[Auth] Could not verify cloud anchor (Offline/Timeout). Refusing to wipe corrupted DB offline.');
             state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Local DB error. Connect to internet to recover.');
             return;
          }
          
          if (cloudAnchorId == null) {
            if (_repository.currentAuthState == null) {
               print('[Auth] Network is likely down. Refusing to wipe corrupted DB offline.');
               state = state.copyWith(status: AuthStateStatus.locked, errorMessage: 'Local DB error. Connect to internet to recover.');
               return;
            }

            print('[Auth] ZOMBIE DB (SELECT 1 FAIL) + No Cloud. Wiping corrupted .db for fresh start.');
            if (File(dbPath).existsSync()) File(dbPath).deleteSync();
            await anchorService.clearLocalAnchor();
            state = AuthState.vaultCorrupted(
              sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              errorMessage: 'Vault database is corrupted and no cloud backup exists. Starting fresh.',
            );
          } else {
            print('[Auth] ZOMBIE DB (SELECT 1 FAIL) + Cloud exists. Offering restore.');
            if (File(dbPath).existsSync()) File(dbPath).deleteSync();
            await anchorService.clearLocalAnchor();
            state = AuthState.needsRestore(
              sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
            );
          }
          return;
        }
      }

      print('[Auth] Connectivity Test (SELECT 1): OK');
      
      final parityAnchorService = VaultAnchorService();
      final parityChannelId = await parityAnchorService.findNebulaChannel();
      if (parityChannelId != null) {
        final metadata = await parityAnchorService.getCloudMetadata(parityChannelId);
        if (metadata != null) {
          try {
            final cleanSalt = metadata['Salt']!.split('\n').first.split('#').first.trim();
            final cleanIv = metadata['IV']!.split('\n').first.split('#').first.trim();
            final cleanEnc = metadata['EncMnemonic']!.split('\n').first.split('#').first.trim();
            
            final salt = Uint8List.fromList(hex.decode(cleanSalt));
            final iv = Uint8List.fromList(hex.decode(cleanIv));
            final encMnemonic = Uint8List.fromList(hex.decode(cleanEnc));
            
            final key = await CryptoUtils.pbkdf2Async(password: password, salt: salt, iterations: 600000);
            final dec = CryptoUtils.aesGcmDecrypt(encMnemonic, key, iv);
            
            if (dec == null) {
              print('[Auth] CRITICAL: Local password valid, but Cloud uses a DIFFERENT password (changed elsewhere).');
              NebulaApi.instance.cleanup();
              final docsDir = await getNebulaDocumentsDirectory();
              final dbFile = File(p.join(docsDir.path, 'nebula.db'));
              if (dbFile.existsSync()) dbFile.deleteSync();
              await parityAnchorService.clearLocalAnchor();
              
              state = state.copyWith(
                status: AuthStateStatus.needsRestore,
                errorMessage: 'Password was changed on another device. Please Restore.',
                sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
              );
              return; 
            } else {
              print('[Auth] Cloud Parity Check: PASS.');
            }
          } catch (e) {
            print('[Auth] Cloud Parity Check ERROR (ignoring): $e');
          }
        }
      }
      
      if (_repository.currentAuthState == null) {
         final creds = await _credsRepository.getCredentials();
         if (creds != null) {
            print('[Auth] DB Unlocked offline. Pulling credentials to start TDLib...');
            final docsDir = await getNebulaDocumentsDirectory();
            await _startTDLib(creds, docsDir.path);
         }
      }

      final localMnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
      if (localMnemonic != null) {
        print('[Auth] Mnemonic successfully retrieved for Late-Stage Healing.');
        final localMnemonicBytes = CryptoUtils.mnemonicToBytes(localMnemonic);
        try {
          print('[Auth] Local Vault Decrypted. Attempting Late-Stage Healing...');
          final anchorService = VaultAnchorService();
          
          int? tgUserId;
          try {
            tgUserId = await _repository.getMe();
          } catch (e) {
            print('[Auth] Offline: Could not fetch Telegram User ID for Healing.');
          }

          if (tgUserId != null) {
            await anchorService.ensureAnchor(
              mnemonic: localMnemonic, 
              tgUserId: tgUserId, 
              password: password
            );
          }
        } finally {
          CryptoUtils.secureClear(localMnemonicBytes);
        }
      }

      final anchorService = VaultAnchorService();
      final channelId = await anchorService.findNebulaChannel();
      if (channelId != null) {
        final cloudHash = await anchorService.getHashFromDescription(channelId);
        final currentLocalHash = await anchorService.getLocalIdentityHash();
        if (cloudHash != null && cloudHash != currentLocalHash) {
           print('[Auth] Decryption successful. Aligning metadata with Cloud Hash: $cloudHash');
           await anchorService.saveLocalAnchor(identityHash: cloudHash);
        }
      }

      // Derive Session Key for VFS Security Hardening
      final sessionKey = await CryptoUtils.pbkdf2Async(
        password: password,
        salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
        iterations: 100000,
      );
      SyncEngine().setMasterKey(sessionKey);
      final mnemonic = NebulaApi.instance.getSetting('vault_mnemonic');
      if (mnemonic != null) {
        final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonic);
        SyncEngine().setMasterKey(vmk);
        SyncEngine().initializeRealTimeListener();
      }

      state = state.copyWith(
        status: AuthStateStatus.ready, 
        masterKey: 'LOCAL_UNLOCKED',
        tempPassword: password, // Keep for potential re-derivation if needed
        clearError: true,
        sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
      );
      
      if (_repository.currentAuthState?['@type'] == 'authorizationStateReady') {
         _initVaultAnchoring(manualMnemonic: localMnemonic);
      }

      print('[Auth] Unlock complete. Triggering background VFS catch-up pull...');
      SyncEngine().pull();
    } else {
      print('[Auth] Local Vault Unlock FAILED (code: $result). Checking cloud sync...');
      
      final anchorService = VaultAnchorService();
      final channelId = await anchorService.findNebulaChannel();
      if (channelId != null) {
        final cloudHash = await anchorService.getHashFromDescription(channelId);
        final localHash = await anchorService.getLocalIdentityHash();
        
        if (localHash != null && cloudHash != null && localHash != cloudHash) {
          print('[Auth] Identity mismatch during login. Suggesting Restore.');
          state = state.copyWith(
            status: AuthStateStatus.locked,
            errorMessage: 'Identity mismatch. Please Restore from Cloud.',
          );
          return;
        }
      }

      state = state.copyWith(
        status: AuthStateStatus.locked,
        errorMessage: 'Invalid vault password.',
      );
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
      print('[Auth] Manual Mnemonic Recovery attempt...');
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

        // Derive Session Key for VFS Security Hardening
        final sessionKey = await CryptoUtils.pbkdf2Async(
          password: password,
          salt: Uint8List.fromList(utf8.encode('NEBULA_SESSION_SALT')),
          iterations: 100000, 
        );
        SyncEngine().setMasterKey(sessionKey);
        final vmk = NebulaApi.instance.deriveMasterKeyBytes(mnemonic);
        SyncEngine().setMasterKey(vmk);
        SyncEngine().initializeRealTimeListener();

        state = state.copyWith(
          status: AuthStateStatus.ready,
          masterKey: 'MNEMONIC_RECOVERED',
          sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
        );
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

  void logOut() {
    print('[Auth] Manual LogOut triggered (Session destruction).');
    _repository.logOut();
    _isAnchoring = false;
    state = const AuthState.initial();
  }

  void triggerRecovery() async {
    print('[Auth] Recovery triggered. Deleting local vault while preserving Telegram.');
    await _wipeVault();
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
      if (await dbDir.exists()) {
        print('[Auth] Deleting TDLib directory: ${dbDir.path}');
        await dbDir.delete(recursive: true);
      }
    } catch (e) {
      print('[Auth] Note: TDLib cleanup failed: $e');
    }
  }

  Future<void> _wipeVault() async {
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
        await prefs.remove(key);
      }
      print('[Auth] WIPE: Cleared ${keysToRemove.length} SharedPreferences keys.');
      
      final anchorService = VaultAnchorService();
      await anchorService.clearLocalAnchor();
      
      _tempMnemonic = null;
      _tempUnlockPassword = null;
      
      print('[Auth] WIPE COMPLETE: All local vault state destroyed.');
    } catch (e) {
      print('[Auth] WIPE ERROR: $e');
    }
  }

  Future<void> confirmSync() async {
    print('[Auth] User confirmed sync (Audit H-01). Stopping background loops...');
    _isCloudChecking = false;
    _isAnchoring = false;
    _isRestoring = false;

    await _wipeVault();
    
    if (mounted) {
      state = AuthState.needsRestore(
        sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
      );
      print('[Auth] Vault wiped. State set to needsRestore.');
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
    state = const AuthState.initial().copyWith(status: AuthStateStatus.loading);
    print('[Auth] Start Fresh chosen. Wiping corrupted local DB...');
    await _wipeVault();
    state = const AuthState.needsVaultSetup();
  }
  
  void setManualChatId(int id) {
    print('[Auth] Setting Manual Chat ID: $id');
    state = state.copyWith(manualChatId: id);
  }

  void forceRestoreState() {
    print('[Auth] Manual Force Sync requested. Transitioning to Restore screen.');
    state = AuthState.needsRestore(
      sessionTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
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
}
