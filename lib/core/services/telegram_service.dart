import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:nebula_core/nebula_core.dart';
import '../api/nebula_api.dart';

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
  final Map<int, Completer<Map<String, dynamic>>> _pendingMessages = {};
  final Map<int, Completer<String>> _pendingDownloads = {};
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
    try {
      final type = update['@type'];

      if (type == 'updateFile') {
        final file = update['file'] as Map?;
        final fileId = file?['id'] as int?;
        final local = file?['local'] as Map?;
        final isCompleted = local?['is_downloading_completed'] as bool? ?? false;
        final path = local?['path'] as String?;
        
        if (fileId != null && isCompleted && path != null && _pendingDownloads.containsKey(fileId)) {
          _log('[DOWNLOAD] File $fileId download COMPLETED at $path');
          _pendingDownloads[fileId]!.complete(path);
          _pendingDownloads.remove(fileId);
        }
      }

      if (type == 'updateMessageSendSucceeded') {
        final oldId = update['old_message_id'] as int?;
        final finalMessage = update['message'] as Map<String, dynamic>?;
        
        if (oldId != null && finalMessage != null && _pendingMessages.containsKey(oldId)) {
          _log('[MSG_SYNC] Message $oldId confirmed SUCCEEDED. Mapping to final state.');
          _pendingMessages[oldId]!.complete(finalMessage);
          _pendingMessages.remove(oldId);
        }
      }

      if (type == 'updateMessageSendFailed') {
        final oldId = update['old_message_id'] as int?;
        final error = update['error_message'] as String? ?? 'Message send failed';
        
        if (oldId != null && _pendingMessages.containsKey(oldId)) {
          _log('[MSG_SYNC] Message $oldId FAILED: $error');
          _pendingMessages[oldId]!.completeError(Exception(error));
          _pendingMessages.remove(oldId);
        }
      }

      if (type == 'updateAuthorizationState') {
        _lastAuthState = update['authorization_state'] as Map<String, dynamic>?; 
        final authState = _lastAuthState?['@type'];
        
        _log('Auth State Update: $authState');

        if (authState == 'authorizationStateWaitTdlibParameters') {
          if (_apiId != null && _apiHash != null && _dbPath != null) {
            _log('Sending TDLib parameters...');
            _ffi.setTdlibParameters(_dbPath!, _apiId!, _apiHash!);
          } else {
            _log('ERROR: Credentials missing during parameter request');
          }
        } else if (authState == 'authorizationStateWaitOtherDeviceConfirmation') {
          final link = _lastAuthState?['link'];
          _log('\n🚨🚨🚨 QR CODE LOGIN READY 🚨🚨🚨');
          _log('🚨 LINK: $link');
          _log('🚨 SCAN THIS LINK IN YOUR TELEGRAM APP (Settings > Devices > Link Desktop Device)');
          _log('🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨\n');
        } else if (authState == 'authorizationStateClosed') {
          _log('TDLib session closed. Allowing re-initialization.');
          _initialized = false;
        }
      }
    } catch (e, stack) {
      _log('[ERROR] Critical failure parsing TDLib update: $e');
      if (kDebugMode) {
        print('UPDATE PARSING CRASH: $e \n $stack');
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

  Future<Map<String, dynamic>?> getChat(int chatId) async {
    final extra = 'nebula_getChat_$chatId';
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];
      if (type == 'chat') {
        if (!completer.isCompleted) {
          completer.complete(update.cast<String, dynamic>());
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer.complete(null);
          sub?.cancel();
        }
      }
    });

    send({'@type': 'getChat', 'chat_id': chatId, '@extra': extra});

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub?.cancel();
        return null;
      },
    );
  }

  Future<Map<String, dynamic>?> getChatMember(int chatId, int userId) async {
    final extra = 'nebula_getChatMember_${chatId}_$userId';
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];
      if (type == 'chatMember') {
        if (!completer.isCompleted) {
          completer.complete(update.cast<String, dynamic>());
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer.complete(null);
          sub?.cancel();
        }
      }
    });

    send({
      '@type': 'getChatMember',
      'chat_id': chatId,
      'member_id': {
        '@type': 'messageSenderUser',
        'user_id': userId,
      },
      '@extra': extra
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub?.cancel();
        return null;
      },
    );
  }

  Future<List<Map<String, dynamic>>> getChatHistory({
    required int chatId,
    int limit = 10,
    int fromMessageId = 0,
  }) async {
    final extra = 'nebula_getHistory_${chatId}_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<List<Map<String, dynamic>>>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];
      if (type == 'messages') {
        final messages = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (!completer.isCompleted) {
          completer.complete(messages);
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer.completeError(
              NebulaError(update['code'] as int? ?? 0, update['message'] as String? ?? 'getChatHistory failed'));
          sub?.cancel();
        }
      }
    });

    send({
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': limit,
      'only_local': false,
      '@extra': extra
    });

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub?.cancel();
        return [];
      },
    );
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

  Future<Map<String, dynamic>?> getFile(int fileId) async {
    final extra = 'nebula_getFile_$fileId';
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];
      if (type == 'file') {
        if (!completer.isCompleted) {
          completer.complete(update.cast<String, dynamic>());
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer.complete(null);
          sub?.cancel();
        }
      }
    });

    send({'@type': 'getFile', 'file_id': fileId, '@extra': extra});

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub?.cancel();
        return null;
      },
    );
  }

  Future<Map<String, dynamic>?> getMessage(int chatId, int messageId) async {
    final extra = 'nebula_getMessage_${chatId}_$messageId';
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];
      if (type == 'message') {
        if (!completer.isCompleted) {
          completer.complete(update.cast<String, dynamic>());
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer.complete(null);
          sub?.cancel();
        }
      }
    });

    send({
      '@type': 'getMessage',
      'chat_id': chatId,
      'message_id': messageId,
      '@extra': extra,
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub?.cancel();
        return null;
      },
    );
  }

  Future<String> downloadFile(int fileId, {int priority = 1}) async {
    final extra = 'nebula_download_$fileId';
    final completer = Completer<String>();
    
    final file = await getFile(fileId);
    if (file != null) {
      final local = file['local'] as Map?;
      if (local?['is_downloading_completed'] == true && local?['path'] != null) {
        final path = local!['path'] as String;
        if (File(path).existsSync()) {
          _log('[DOWNLOAD] File $fileId already available at $path');
          return path;
        } else {
          _log('[DOWNLOAD] TDLib cache points to missing file ($path). Forcing redownload...');
        }
      }
    }

    _log('[DOWNLOAD] Requesting download for File $fileId (Priority: $priority)...');
    _pendingDownloads[fileId] = completer;

    send({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': priority,
      'offset': 0,
      'limit': 0,
      'synchronous': false,
      '@extra': extra,
    });

    try {
      return await completer.future.timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          _pendingDownloads.remove(fileId);
          throw TimeoutException('Download for file $fileId timed out after 10 minutes');
        },
      );
    } catch (e) {
      _pendingDownloads.remove(fileId);
      rethrow;
    }
  }


  Future<(int, int)> sendDocument({
    required int chatId,
    required String filePath,
    String? caption,
  }) async {
    final extra = 'nebula_sendDoc_${DateTime.now().microsecondsSinceEpoch}';
    final initialCompleter = Completer<int>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];

      if (type == 'message') {
        final msgId = update['id'] as int;
        if (!initialCompleter.isCompleted) {
          initialCompleter.complete(msgId);
          sub?.cancel();
        }
      } else if (type == 'error') {
        if (!initialCompleter.isCompleted) {
          initialCompleter.completeError(
              NebulaError(update['code'] as int? ?? 0, update['message'] as String? ?? 'Unknown error'));
          sub?.cancel();
        }
      }
    });

    send({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageDocument',
        'document': {
          '@type': 'inputFileLocal',
          'path': filePath,
        },
        'force_file': true,
        'disable_content_type_detection': true,
        if (caption != null)
          'caption': {
            '@type': 'formattedText',
            'text': caption,
          },
      },
      '@extra': extra,
    });

    final tempMsgId = await initialCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('sendDocument initial call timed out'),
    );

    _log('[MSG_SEND] Initial message sent. TempID: $tempMsgId. Registering lifecycle watcher...');

    final finalCompleter = Completer<Map<String, dynamic>>();
    _pendingMessages[tempMsgId] = finalCompleter;

    try {
      final finalMessage = await finalCompleter.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          _pendingMessages.remove(tempMsgId);
          throw TimeoutException('sendDocument confirmation timed out after 5 minutes');
        },
      );

      final finalMsgId = finalMessage['id'] as int;
      final content = finalMessage['content'] as Map<String, dynamic>?;
      
      if (content == null || content['@type'] != 'messageDocument') {
        throw Exception('Unexpected message content type after upload confirmation');
      }

      final fileId = content['document']['document']['id'] as int;
      
      _log('[MSG_SEND] Upload confirmed! FinalMsgID: $finalMsgId, RemoteFileID: $fileId');
      return (finalMsgId, fileId);

    } catch (e) {
      _log('[MSG_ERROR] Send failed for TempID $tempMsgId: $e');
      _pendingMessages.remove(tempMsgId);
      rethrow;
    }
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
