import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:nebula_core/nebula_core.dart';
import 'package:nebula_client/core/config/telegram_config.dart';

class TelegramService {
  static final TelegramService _instance = TelegramService._internal();
  factory TelegramService() => _instance;
  TelegramService._internal();

  final NebulaFFI _ffi = NebulaFFI();
  final ReceivePort _updatesPort = ReceivePort();
  StreamSubscription? _updatesSubscription;
  
  bool _initialized = false;
  
  final _updatesController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updatesController.stream;

  void init() {
    if (_initialized) return;

    try {
      _ffi.initDartApi();

      _updatesSubscription = _updatesPort.listen((message) {
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

      if (!TelegramConfig.isValid) {
        _log('Telegram credentials not configured');
        return;
      }

      final portId = _updatesPort.sendPort.nativePort;
      _ffi.startTelegram(portId, TelegramConfig.apiId, TelegramConfig.apiHash);
      
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
       _log('Auth State Update: ${update['authorization_state']['@type']}');
    }
  }

  void dispose() {
    _ffi.stopTelegram();
    _updatesSubscription?.cancel();
    _updatesPort.close();
    _updatesController.close();
    _initialized = false;
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[TELEGRAM] $message');
    }
  }
}
