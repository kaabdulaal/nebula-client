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
  static TelegramService get instance => _instance;
  factory TelegramService() => _instance;
  TelegramService._internal();

  final NebulaFFI _ffi = NebulaFFI();
  ReceivePort? _updatesPort;
  StreamSubscription? _updatesSubscription;

  bool _initialized = false;
  bool _isHighPriorityActive = false;
  
  void setHighPriorityTask(bool active) {
    _log('[PRIORITY] High-priority task: $active');
    _isHighPriorityActive = active;
  }

  final _updatesController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updatesController.stream;

  final _fileProgressController = StreamController<(int, double)>.broadcast();
  Stream<(int, double)> get fileProgress => _fileProgressController.stream;

  Map<String, dynamic>? _lastAuthState;
  final Map<int, Completer<Map<String, dynamic>>> _pendingMessages = {};
  Map<int, Completer<String>> _pendingDownloads = {};
  Map<String, dynamic>? get currentAuthState => _lastAuthState;

  int _lastServerTime = 0;
  DateTime? _lastSyncTime;

  int get serverTime {
    if (_lastSyncTime == null) return DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final elapsed = DateTime.now().difference(_lastSyncTime!).inSeconds;
    return _lastServerTime + elapsed;
  }

  void _syncTime(int? serverUnixTime) {
    if (serverUnixTime == null || serverUnixTime <= 0) return;
    if (serverUnixTime > _lastServerTime) {
      _lastServerTime = serverUnixTime;
      _lastSyncTime = DateTime.now();
    }
  }

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
            if (json is Map<String, dynamic>) {
              _updatesController.add(json);
              _handleInternalUpdate(json);
            } else {
              _log('Dropped non-Map TDLib event: ${json.runtimeType}');
            }
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
        final size = file?['size'] as int? ?? 1;
        final local = file?['local'] as Map?;
        final downloadedSize = local?['downloaded_size'] as int? ?? 0;
        final isCompleted = local?['is_downloading_completed'] as bool? ?? false;
        final path = local?['path'] as String?;
        
        if (fileId != null) {
          final progress = downloadedSize / size;
          _fileProgressController.add((fileId, progress));
        }

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

      if (update.containsKey('message')) {
        final msg = update['message'];
        if (msg is Map && msg.containsKey('date')) {
          _syncTime(msg['date'] as int?);
        }
      } else if (type == 'updateNewMessage') {
        final msg = update['message'];
        if (msg is Map) {
          _syncTime(msg['date'] as int?);
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
        debugPrint('UPDATE PARSING CRASH: $e \n $stack');
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

  void addProxy({
    required String server,
    required int port,
    required String type,
    String? username,
    String? password,
    String? secret,
    bool enable = true,
  }) {
    final proxyType = {
      '@type': type,
      if (type == 'proxyTypeSocks5' || type == 'proxyTypeHttp') ...{
        'username': username ?? '',
        'password': password ?? '',
      },
      if (type == 'proxyTypeMtproto') 'secret': secret ?? '',
    };

    send({
      '@type': 'addProxy',
      'server': server,
      'port': port,
      'enable': enable,
      'type': proxyType,
    });
  }

  void disableProxy() {
    send({'@type': 'disableProxy'});
  }

  Future<Map<String, dynamic>?> getProxies() async {
    final extra = 'nebula_getProxies_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      if (update['@type'] == 'proxies') {
        completer.complete(update.cast<String, dynamic>());
      } else {
        completer.complete(null);
      }
      sub?.cancel();
    });

    send({'@type': 'getProxies', '@extra': extra});
    return completer.future.timeout(const Duration(seconds: 2), onTimeout: () {
      sub?.cancel();
      return null;
    });
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
    int offset = 0,
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
      'offset': offset,
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

  Future<List<Map<String, dynamic>>> searchMessages({
    required int chatId,
    required String query,
    int fromMessageId = 0,
    int limit = 100,
    Map<String, dynamic>? filter,
  }) async {
    final extra = 'nebula_search_${chatId}_${DateTime.now().microsecondsSinceEpoch}';
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
              NebulaError(update['code'] as int? ?? 0, update['message'] as String? ?? 'searchMessages failed'));
          sub?.cancel();
        }
      }
    });

    send({
      '@type': 'searchChatMessages',
      'chat_id': chatId,
      'query': query,
      'filter': filter ?? {'@type': 'searchMessagesFilterEmpty'},
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': limit,
      '@extra': extra,
    });

    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        sub?.cancel();
        return [];
      },
    );
  }

  Future<List<Map<String, dynamic>>> getPinnedMessages(int chatId) async {
    return searchMessages(
      chatId: chatId,
      query: '',
      filter: {'@type': 'searchMessagesFilterPinned'},
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
      final path = local?['path'] as String?;
      
      if (path != null && path.isNotEmpty) {
        if (File(path).existsSync()) {
          if (local?['is_downloading_completed'] == true) {
            _log('[DOWNLOAD] File $fileId already available at $path');
            return path;
          }
        } else {
          _log('[DOWNLOAD] TDLib cache points to missing file ($path). Clearing local record to force re-download...');
          await deleteFile(fileId);
          await getFile(fileId);
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
      return await completer.future;
    } catch (e) {
      _pendingDownloads.remove(fileId);
      rethrow;
    }
  }


  Future<Map<String, dynamic>?> _getMessageContent(int chatId, int messageId) async {
    final msg = await getMessage(chatId, messageId);
    if (msg == null) return null;
    return msg['content'] as Map<String, dynamic>?;
  }

  Future<(int, int)> sendDocument({
    required int chatId,
    required String filePath,
    String? caption,
    void Function(double)? onProgress,
  }) async {
    if (_isHighPriorityActive && (caption?.contains('#NEBULA_') ?? false)) {
      _log('[PRIORITY] Throttling background sync document...');
      await Future.delayed(const Duration(milliseconds: 2000));
    }

    final extra = 'nebula_sendDoc_${DateTime.now().microsecondsSinceEpoch}';
    final initialCompleter = Completer<int>();
    StreamSubscription? sub;
    StreamSubscription? progressSub;

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

    final tempMsgId = await initialCompleter.future;

    _log('[MSG_SEND] Initial message sent. TempID: $tempMsgId. Registering lifecycle watcher...');

    if (onProgress != null) {
      int? trackingFileId;
      try {
        final content = await _getMessageContent(chatId, tempMsgId);
        if (content != null && content['@type'] == 'messageDocument') {
          trackingFileId = content['document']?['document']?['id'] as int?;
        }
      } catch (_) {}

      progressSub = _updatesController.stream.listen((update) {
        if (update['@type'] == 'updateMessageSendSucceeded' || update['@type'] == 'updateMessageSendFailed') {
          final oldId = update['old_message_id'] as int?;
          if (oldId == tempMsgId) progressSub?.cancel();
          return;
        }

        if (trackingFileId == null && update['@type'] == 'updateMessageContent' && update['message_id'] == tempMsgId) {
          final content = update['new_content'];
          if (content != null && content['@type'] == 'messageDocument') {
            trackingFileId = content['document']?['document']?['id'] as int?;
            _log('[PROGRESS] Discovered trackingFileId via updateMessageContent: $trackingFileId');
          }
        }

        if (update['@type'] == 'updateFile' && trackingFileId != null) {
          final file = update['file'] as Map?;
          if (file?['id'] == trackingFileId) {
            final expectedSize = file?['expected_size'] as int? ?? file?['size'] as int? ?? 1;
            final remote = file?['remote'] as Map?;
            final uploadedSize = remote?['uploaded_size'] as int? ?? 0;
            if (expectedSize > 0 && uploadedSize > 0) {
              final progress = uploadedSize / expectedSize;
              onProgress(progress.clamp(0.0, 1.0));
            }
          }
        }
      });
    }

    final finalCompleter = Completer<Map<String, dynamic>>();
    _pendingMessages[tempMsgId] = finalCompleter;

    try {
      final finalMessage = await finalCompleter.future;

      final finalMsgId = finalMessage['id'] as int;
      final content = finalMessage['content'] as Map<String, dynamic>?;
      
      if (content == null || content['@type'] != 'messageDocument') {
        throw Exception('Unexpected message content type after upload confirmation');
      }

      final fileId = content['document']['document']['id'] as int;
      
      _log('[MSG_SEND] Upload confirmed! FinalMsgID: $finalMsgId, RemoteFileID: $fileId');
      progressSub?.cancel();
      return (finalMsgId, fileId);

    } catch (e) {
      _log('[MSG_ERROR] Send failed for TempID $tempMsgId: $e');
      _pendingMessages.remove(tempMsgId);
      progressSub?.cancel();
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


  Future<int> sendTextMessage({
    required int chatId,
    required String text,
  }) async {
    if (_isHighPriorityActive && text.contains('#NEBULA_')) {
      _log('[PRIORITY] Throttling background sync text message...');
      await Future.delayed(const Duration(milliseconds: 500));
    }

    final extra = 'nebula_sendMsg_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<int>();
    StreamSubscription? sub;

    sub = _updatesController.stream.listen((update) {
      if (update['@extra'] != extra) return;
      if (update['@type'] == 'message') {
        completer.complete(update['id'] as int);
        sub?.cancel();
      } else if (update['@type'] == 'error') {
        completer.completeError(Exception(update['message']));
        sub?.cancel();
      }
    });

    send({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': text,
        },
      },
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> pinChatMessage(int chatId, int messageId) async {
    final extra = 'pin_$messageId';
    send({
      '@type': 'pinChatMessage',
      'chat_id': chatId,
      'message_id': messageId,
      'disable_notification': true,
      'only_for_self': false,
      '@extra': extra,
    });
    _log('[PIN] Requested pin for Message $messageId in Chat $chatId');
  }

  Future<void> unpinChatMessage(int chatId, int messageId) async {
    send({
      '@type': 'unpinChatMessage',
      'chat_id': chatId,
      'message_id': messageId,
    });
    _log('[UNPIN] Requested unpin for Message $messageId in Chat $chatId');
  }

  Future<void> deleteMessages({
    required int chatId,
    required List<int> messageIds,
    bool revoke = true,
  }) async {
    if (messageIds.isEmpty) return;
    
    send({
      '@type': 'deleteMessages',
      'chat_id': chatId,
      'message_ids': messageIds,
      'revoke': revoke,
    });
    _log('[DELETE] Requested deletion of ${messageIds.length} messages in Chat $chatId');
  }

  Future<void> deleteFile(int fileId) async {
    final extra = 'delete_file_$fileId';
    send({
      '@type': 'deleteFile',
      'file_id': fileId,
      '@extra': extra,
    });
    _log('[CACHE] Requested deletion of file record $fileId');
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[TELEGRAM] $message');
    }
  }
}
