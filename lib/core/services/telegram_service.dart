import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:nebula_core/nebula_core.dart';

export 'dart:async' show TimeoutException;

class TelegramService {
  static final TelegramService _instance = TelegramService._internal();
  factory TelegramService() => _instance;
  TelegramService._internal();

  final NebulaFFI _ffi = NebulaFFI();
  ReceivePort? _updatesPort;
  StreamSubscription? _updatesSubscription;

  bool _initialized = false;

  final _updatesController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updatesController.stream;

  Map<String, dynamic>? _lastAuthState;
  Map<String, dynamic>? get currentAuthState => _lastAuthState;

  bool get isAuthorized => _lastAuthState?['@type'] == 'authorizationStateReady';

  int? _apiId;
  String? _apiHash;
  String? _dbPath;

  Future<void> init({required int apiId, required String apiHash, required String dbPath}) async {
    if (_initialized) return;

    _apiId = apiId;
    _apiHash = apiHash;
    _dbPath = dbPath;

    try {
      _log('Initializing with API_ID: $apiId');
      
      await _updatesSubscription?.cancel();
      _updatesPort?.close();
      _updatesPort = ReceivePort();
      
      _updatesSubscription = _updatesPort!.listen((message) {
        if (message is String) {
          try {
            final json = jsonDecode(message);
            _updatesController.add(json);
            _handleInternalUpdate(json);
          } catch (e) {
            _log('Failed to parse update: $e');
          }
        }
      });

      _ffi.initDartApi();
      
      _ffi.sendTelegramRequest(jsonEncode({'@type': 'setLogStream', 'log_stream': {'@type': 'logStreamEmpty'}}));
      _ffi.sendTelegramRequest(jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 0}));

      final portId = _updatesPort!.sendPort.nativePort;
      _ffi.startTelegram(portId);

      _initialized = true;
      _log('Service initialized');
    } catch (e) {
      _log('Initialization failed: $e');
    }
  }

  void send(Map<String, dynamic> request) {
    if (!_initialized) {
      _log('Not initialized');
      return;
    }

    final jsonStr = jsonEncode(request);
    _ffi.sendTelegramRequest(jsonStr);
  }

  void _handleInternalUpdate(Map<String, dynamic> update) {
    final type = update['@type'];
    if (type == 'updateAuthorizationState') {
      _lastAuthState = update['authorization_state']; 
      final authState = _lastAuthState!['@type'];
      
      _log('Auth State Update: $authState');

      if (authState == 'authorizationStateWaitTdlibParameters') {
        if (_apiId != null && _apiHash != null && _dbPath != null) {
          _log('Sending TDLib parameters...');
          _ffi.setTdlibParameters(_dbPath!, _apiId!, _apiHash!);
        } else {
          _log('ERROR: Credentials missing during parameter request');
        }
      } else if (authState == 'authorizationStateWaitOtherDeviceConfirmation') {
        final link = _lastAuthState!['link'];
        _log('\n🚨🚨🚨 QR CODE LOGIN READY 🚨🚨🚨');
        _log('🚨 LINK: $link');
        _log('🚨 SCAN THIS LINK IN YOUR TELEGRAM APP (Settings > Devices > Link Desktop Device)');
        _log('🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨\n');
      } else if (authState == 'authorizationStateClosed') {
        _log('TDLib session closed. Allowing re-initialization.');
        _initialized = false;
      }
    }
  }


  void sendPhoneNumber(String phone) {
    _ffi.sendAuthenticationPhoneNumber(phone);
  }

  void checkCode(String code) {
    _ffi.checkAuthenticationCode(code);
  }

  void checkPassword(String password) {
    _ffi.checkAuthenticationPassword(password);
  }

  void logOut() {
    _ffi.logOut();
  }

  void resendAuthenticationCode() {
    send({'@type': 'resendAuthenticationCode'});
  }

  void requestQrCodeAuthentication() {
    send({'@type': 'requestQrCodeAuthentication'});
  }

  void requestAuthState() {
    send({'@type': 'getAuthorizationState'});
  }

  Future<int> getMe() async {
    const extra = 'nebula_getMe';
    final completer = Completer<int>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];
      if (type == 'user') {
        final id = update['id'] as int?;
        if (id != null && !completer.isCompleted) {
          completer.complete(id);
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer.completeError(
              Exception('getMe failed: ${update['message']}'));
          sub?.cancel();
        }
      }
    });

    send({'@type': 'getMe', '@extra': extra});

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub?.cancel();
        throw TimeoutException('getMe timed out after 10s');
      },
    );
  }

  void dispose() {
    if (!_initialized) return;
    _log('Disposing Telegram service (Graceful Shutdown)...');

    send({'@type': 'close'});
    
    _ffi.stopTelegram();
    
    _updatesSubscription?.cancel();
    _updatesSubscription = null;
    _updatesPort?.close();
    _updatesPort = null;
    
    _initialized = false;
    _lastAuthState = null;
    _log('Service disposed.');
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[TELEGRAM] $message');
    }
  }
}
