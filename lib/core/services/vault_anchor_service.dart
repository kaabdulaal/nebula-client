import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:convert/convert.dart';
import 'package:nebula_client/core/utils/crypto_utils.dart';
import '../api/nebula_api.dart';
import 'telegram_service.dart';

class VaultAnchorService {
  static const String _channelName = 'Nebula Vault';
  static const String _hashPrefix = 'IdentityHash: ';
  static const String _epochSeparator = ' | Epoch: ';
  static const String _metaPrefix = 'NEBULA_META|';

  final TelegramService _telegram;

  VaultAnchorService({TelegramService? telegramService})
      : _telegram = telegramService ?? TelegramService();

  Future<void> waitForTelegramReady() async {
    if (_telegram.isAuthorized) return;

    _log('Waiting for Telegram authorization (needed for Cloud Anchor)...');
    final completer = Completer<void>();
    StreamSubscription? sub;

    sub = _telegram.updates.listen((update) {
      if (_telegram.isAuthorized) {
        if (!completer.isCompleted) completer.complete();
        sub?.cancel();
      }
    });

    final timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (_telegram.isAuthorized) {
        if (!completer.isCompleted) completer.complete();
        sub?.cancel();
        t.cancel();
      }
    });

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub?.cancel();
        timer.cancel();
        _log('Timeout waiting for Telegram authorization.');
        throw TimeoutException('Telegram not authorized after 10s');
      },
    );
  }


  String computeIdentityHash(String mnemonic, int tgUserId) {
    final normalizedMnemonic = mnemonic.trim().toLowerCase();
    final input = '$normalizedMnemonic|$tgUserId';
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }


  Future<int?> findNebulaChannel({bool forceRefresh = false, String? expectedHash}) async {
    _log('[DEBUG] findNebulaChannel called. forceRefresh: $forceRefresh');
    try {
      await waitForTelegramReady();
    } catch (_) {
      _log('[ERROR] findNebulaChannel: Telegram NOT READY.');
      return null;
    }

    if (!forceRefresh && NebulaApi.instance.isInitialized) {
      final dbIdStr = NebulaApi.instance.getSetting('vault_channel_id');
      if (dbIdStr != null) {
        final dbId = int.tryParse(dbIdStr);
        if (dbId != null) {
          _log('Found cached channel ID in DB: $dbId. Verifying...');
          if (await _verifyChatHealthy(dbId, expectedHash)) {
            return dbId;
          }
          _log('DB Channel ID $dbId is invalid/stale. Clearing.');
          NebulaApi.instance.setSetting('vault_channel_id', '');
        }
      }
    }

    final prefs = await SharedPreferences.getInstance();
    if (!forceRefresh) {
      final cachedId = prefs.getInt('vault_channel_id');
      if (cachedId != null) {
        if (await _verifyChatHealthy(cachedId, expectedHash)) {
          if (NebulaApi.instance.isInitialized) {
            NebulaApi.instance.setSetting('vault_channel_id', cachedId.toString());
          }
          return cachedId;
        }
        await prefs.remove('vault_channel_id');
      }
    }

    _log('Performing Server-Side Discovery for "$_channelName"...');
    final foundId = await _searchNebulaChat();
    
    if (foundId != null) {
      if (await _verifyChatHealthy(foundId, expectedHash)) {
        _log('Discovery SUCCESS: Found "$_channelName" at ID $foundId.');
        await prefs.setInt('vault_channel_id', foundId);
        if (NebulaApi.instance.isInitialized) {
          NebulaApi.instance.setSetting('vault_channel_id', foundId.toString());
        }
        return foundId;
      }
    }

    _log('Discovery: No valid "$_channelName" channel found.');
    return null;
  }

  Future<bool> _verifyChatHealthy(int chatId, String? expectedHash) async {
    try {
      final chat = await _getChat(chatId);
      if (chat == null) return false;

      final title = chat['title'] as String? ?? '';
      if (title != _channelName) return false;

      if (expectedHash != null) {
        final isValid = await verifyVaultSignature(chatId, expectedHash);
        if (!isValid) {
          _log('Handshake Failed: IdentityHash signature mismatch in pinned message for chat $chatId');
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> verifyVaultSignature(int chatId, String expectedHash) async {
    final pinnedMsg = await _getChatPinnedMessage(chatId);
    if (pinnedMsg == null) {
      _log('Handshake Failed: No pinned message found in chat $chatId');
      return false;
    }

    final meta = _extractMetadataFromMessage(pinnedMsg);
    if (meta == null) {
      _log('Handshake Failed: Pinned message in $chatId is not a Nebula Metadata message');
      return false;
    }

    
    final cloudHash = meta['IdentityHash'];
    if (cloudHash != null) {
      return cloudHash == expectedHash;
    }

    final descHash = await getHashFromDescription(chatId);
    return descHash == expectedHash;
  }

  Future<int?> _searchNebulaChat() async {
    final completer = Completer<int?>();
    StreamSubscription? sub;
    const extra = 'nebula_searchChats_discovery';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];

      if (type == 'chats') {
        final chatIds = (update['chat_ids'] as List?)?.cast<int>() ?? [];
        sub?.cancel();
        _checkChatsForNebula(chatIds).then((id) {
          if (!completer.isCompleted) completer.complete(id);
        });
      } else if (type == 'error') {
        sub?.cancel();
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    _telegram.send({
      '@type': 'searchChats',
      'query': _channelName,
      'limit': 5, 
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
  }

  Future<bool> canUpload(int chatId) async {
    _log('[DEBUG] Checking upload permissions for chat: $chatId');
    try {
      final chat = await _getChat(chatId);
      if (chat == null) return false;

      final type = chat['type']?['@type'];
      if (type == 'chatTypeSupergroup') {
        final userId = await _telegram.getMe();
        final member = await _telegram.getChatMember(chatId, userId);
        final memberStatus = member?['status']?['@type'];
        
        _log('[DEBUG] User Status in chat: $memberStatus');

        if (memberStatus == 'chatMemberStatusCreator') {
          _log('[DEBUG] Owner Bypass active. Proceeding.');
          return true;
        }

        final permissions = chat['permissions'] as Map?;
        _log('[DEBUG] Chat Permissions Flags: $permissions');

        final canSendMessages = permissions?['can_send_messages'] ?? true;
        final canSendDocs = permissions?['can_send_documents'] ?? true;
        
        _log('[DEBUG] canSendMessages: $canSendMessages, canSendDocs: $canSendDocs');
        
        return canSendMessages && canSendDocs;
      }
      return true; 
    } catch (e) {
      _log('[ERROR] canUpload check failed: $e');
      return false;
    }
  }

  Future<void> refreshChatList({int limit = 100}) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    final extra = 'nebula_refresh_chats_${DateTime.now().millisecondsSinceEpoch}';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      completer.complete();
    });

    _telegram.send({
      '@type': 'getChats',
      'limit': limit,
      '@extra': extra,
    });

    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub?.cancel();
      },
    );
  }

  Future<int?> _checkChatsForNebula(List<int> chatIds) async {
    for (final chatId in chatIds) {
      try {
        final chat = await _getChat(chatId);
        if (chat == null) continue;

        final title = chat['title'] as String? ?? '';
        final typeStr = chat['type']?['@type'] as String? ?? '';
        
        final permissions = chat['permissions'] as Map?;
        final canRead = permissions?['can_send_messages'] ?? true; 

        if (title == _channelName && typeStr == 'chatTypeSupergroup' && canRead) {
          return chatId;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getChat(int chatId) async {
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;
    final extra = 'nebula_getChat_$chatId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (update['@type'] == 'chat') {
        if (!completer.isCompleted) completer.complete(update);
      } else if (update['@type'] == 'error') {
        final msg = update['message'] as String? ?? '';
        final code = update['code'] as int? ?? 0;
        
        final isTerminal = code == 404 || code == 400 || 
                           msg.contains('CHANNEL_PRIVATE') || 
                           msg.contains('Can\'t access the chat') ||
                           msg.contains('chat not found');
        
        if (isTerminal) {
           _log('getChat($chatId) TERMINAL error ($code): $msg. Wiping cache.');
           SharedPreferences.getInstance().then((p) => p.remove('vault_channel_id'));
           if (!completer.isCompleted) completer.complete(null);
        } else {
           _log('getChat($chatId) transient error ($code): $msg. Retaining cache.');
           if (!completer.isCompleted) completer.complete(null);
        }
      } else {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    _telegram.send({'@type': 'getChat', 'chat_id': chatId, '@extra': extra});

    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () => null);
  }

  Future<int> createNebulaChannel() async {
    await waitForTelegramReady();
    _log('Creating new "$_channelName" channel...');

    final completer = Completer<int>();
    StreamSubscription? sub;
    const extra = 'nebula_createChannel';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];

      if (type == 'chat') {
        final chatId = update['id'] as int?;
        if (chatId != null && !completer.isCompleted) {
          completer.complete(chatId);
          sub?.cancel();
        }
      } else if (type == 'error' && !completer.isCompleted) {
        final errorMsg = update['message'] as String? ?? '';
        _log('createNebulaChannel TDLib error: $errorMsg. Attempting fallback search...');
        sub?.cancel();
        
        _findExistingChannelFallback().then((existingId) {
          if (existingId != null && !completer.isCompleted) {
            _log('FIX 4: Found existing "$_channelName" at ID $existingId. Auto-linking.');
            SharedPreferences.getInstance().then((p) => p.setInt('vault_channel_id', existingId));
            completer.complete(existingId);
          } else if (!completer.isCompleted) {
            completer.completeError(Exception('createNebulaChannel failed: $errorMsg (and no existing channel found)'));
          }
        }).catchError((e) {
          if (!completer.isCompleted) {
            completer.completeError(Exception('createNebulaChannel failed: $errorMsg'));
          }
        });
      }
    });

    _telegram.send({
      '@type': 'createNewSupergroupChat',
      '@extra': extra,
      'title': _channelName,
      'is_channel': true,
      'description': '', 
      'location': null,
      'for_import': false,
    });

    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () async {
      sub?.cancel();
      _log('createNebulaChannel TIMEOUT. Searching for existing channel...');
      final existingId = await _findExistingChannelFallback();
      if (existingId != null) return existingId;
      throw TimeoutException('Channel creation timed out and no existing channel found');
    });
  }

  Future<int?> _findExistingChannelFallback() async {
    await refreshChatList(limit: 100);
    return _searchNebulaChat();
  }


  Future<void> setCloudMetadata({
    required int channelId,
    required int epoch,
    required String saltHex,
    required String ivHex,
    required String encMnemonicHex,
    required String identityHash,
  }) async {
    await waitForTelegramReady();
    _log('Storing Cloud Metadata (REAL ID Flow)...');

    await cleanupCloudMetadata(channelId);

    final content = '$_metaPrefix'
        'Epoch:$epoch|'
        'Salt:$saltHex|'
        'IV:$ivHex|'
        'EncMnemonic:$encMnemonicHex|'
        'IdentityHash:$identityHash'
        '\n\n#NEBULA_METADATA';

    final completer = Completer<void>();
    StreamSubscription? sub;
    const extra = 'nebula_sendMeta';
    int? tempMessageId;

    sub = _telegram.updates.listen((update) {
      final type = update['@type'];
      if (update['@extra'] == extra && type == 'message') {
        tempMessageId = update['id'] as int;
      }
      else if (type == 'updateMessageSendSucceeded' && 
                 update['old_message_id'] == tempMessageId) {
        final realMessageId = update['message']['id'] as int;
        _pinMessage(channelId, realMessageId).then((_) {
          if (!completer.isCompleted) completer.complete();
          sub?.cancel();
        }).catchError((e) {
          if (!completer.isCompleted) completer.completeError(e);
          sub?.cancel();
        });
      } 
      else if (update['@extra'] == extra && type == 'error') {
        if (!completer.isCompleted) {
          completer.completeError(Exception('Metadata send failed: ${update['message']}'));
        }
        sub?.cancel();
      }
    });

    _telegram.send({
      '@type': 'sendMessage',
      'chat_id': channelId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': content},
      },
      '@extra': extra,
    });

    await completer.future.timeout(const Duration(seconds: 20));
    
    if (tempMessageId != null) {
      await _waitForMessageStatus(channelId, tempMessageId!);
    }
  }

  Future<void> _waitForMessageStatus(int chatId, int messageId) async {
    final existingMsg = await _getMessageById(chatId, messageId);
    if (existingMsg != null) {
      final sendingState = existingMsg['sending_state'];
      if (sendingState == null) {
        _log('Message $messageId already confirmed (no sending_state).');
        return; 
      }
    }
    
    final completer = Completer<void>();
    StreamSubscription? sub;
    
    sub = _telegram.updates.listen((update) {
      if (update['@type'] == 'updateMessageSendSucceeded' && 
          update['old_message_id'] == messageId) {
        sub?.cancel();
        completer.complete();
      } else if (update['@type'] == 'updateMessageSendFailed' && 
                 update['old_message_id'] == messageId) {
        sub?.cancel();
        final errorMsg = update['error']?['message'] ?? 'Unknown';
        _log('Message $messageId send FAILED: $errorMsg');
        completer.completeError(Exception('Message send failed: $errorMsg'));
      }
    });

    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      sub?.cancel();
      _log('Timeout waiting for message status $messageId');
    });
  }
  
  Future<Map<String, dynamic>?> _getMessageById(int chatId, int messageId) async {
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;
    final extra = 'nebula_getMsg_${chatId}_$messageId';
    
    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (update['@type'] == 'message') {
        if (!completer.isCompleted) completer.complete(update);
      } else {
        if (!completer.isCompleted) completer.complete(null);
      }
    });
    
    _telegram.send({
      '@type': 'getMessage',
      'chat_id': chatId,
      'message_id': messageId,
      '@extra': extra,
    });
    
    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () => null);
  }

  Future<void> forceSyncAnchor({
    required Uint8List mnemonic,
    required String password,
    required int tgUserId,
  }) async {
    _log('DIRECT INJECTION: Forcing anchor to cloud...');
    
    final mnemonicStr = CryptoUtils.bytesToMnemonic(mnemonic);
    final channelId = await ensureAnchor(
      mnemonic: mnemonicStr,
      tgUserId: tgUserId,
      password: password,
      isNewVault: true, 
    );

    if (channelId == null) {
      throw Exception('Failed to resolve channel during forced anchor');
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final iv = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
    
    final key = await CryptoUtils.pbkdf2Async(
      password: password,
      salt: salt,
      iterations: 600000,
    );
    
    final encMnemonic = CryptoUtils.aesGcmEncrypt(mnemonic, key, iv);
    
    if (encMnemonic == null) {
      throw Exception('Encryption failed during forced anchor');
    }

    final identityHash = computeIdentityHash(mnemonicStr, tgUserId);
    await setCloudMetadata(
      channelId: channelId,
      epoch: timestamp,
      saltHex: hex.encode(salt),
      ivHex: hex.encode(iv),
      encMnemonicHex: hex.encode(encMnemonic),
      identityHash: identityHash,
    );

    await saveLocalAnchor(
      epoch: timestamp,
      identityHash: identityHash,
    );
    
    _log('DIRECT INJECTION COMPLETE.');
  }

  Future<void> cleanupCloudMetadata(int channelId) async {
    _log('Cleaning up old metadata messages in channel $channelId (Server-Side)...');
    try {
      final msgs = await _searchAllMetadataMessages(channelId);
      if (msgs.isEmpty) {
        _log('No old metadata messages found. Cleanup skipped.');
        return;
      }

      try {
        _telegram.send({'@type': 'unpinAllChatMessages', 'chat_id': channelId});
      } catch (e) {
        _log('Unpin all failed (ignorable): $e');
      }

      final ids = msgs.map((m) => m['id'] as int).toList();
      _telegram.send({
        '@type': 'deleteMessages',
        'chat_id': channelId,
        'message_ids': ids,
        'revoke': true,
      });
      _log('Requested deletion of ${ids.length} old metadata messages.');
    } catch (e) {
      _log('Cleanup Error: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _searchAllMetadataMessages(int chatId) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    StreamSubscription? sub;
    final extra = 'nebula_searchAllMeta_$chatId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (update['@type'] == 'messages') {
        final msgs = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (!completer.isCompleted) completer.complete(msgs);
      } else {
        if (!completer.isCompleted) completer.complete([]);
      }
    });

    _telegram.send({
      '@type': 'searchChatMessages',
      'chat_id': chatId,
      'query': '#NEBULA_METADATA',
      'limit': 50,
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () => []);
  }

  Future<void> _pinMessage(int chatId, int messageId) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    final extra = 'nebula_pin_$messageId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (!completer.isCompleted) completer.complete();
    });

    _telegram.send({
      '@type': 'pinChatMessage',
      'chat_id': chatId,
      'message_id': messageId,
      'disable_notification': true,
      'only_for_self': false,
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 10));
  }

  Future<Map<String, String>?> getCloudMetadata(int channelId) async {
    await waitForTelegramReady();
    _log('Fetching Cloud Metadata for channel $channelId (Sync-Aware)...');
    
    _log('Attempting to fetch metadata (Pinned > History > Sync)...');
    
    final pinnedMsg = await _getChatPinnedMessage(channelId);
    final pinnedMeta = _extractMetadataFromMessage(pinnedMsg);
    if (pinnedMeta != null) return pinnedMeta;

    final history = await _getChatHistory(channelId, limit: 20);
    for (final msg in history) {
      final meta = _extractMetadataFromMessage(msg);
      if (meta != null) return meta;
    }

    for (int attempt = 1; attempt <= 2; attempt++) {
      _log('Metadata not found. Forcing TDLib sync (Attempt $attempt/2)...');
      _telegram.send({
        '@type': 'viewMessages',
        'chat_id': channelId,
        'message_thread_id': 0,
        'message_ids': [], 
        'force_read': true,
      });
      await Future.delayed(const Duration(seconds: 2));
      
      final historyAfterSync = await _getChatHistory(channelId, limit: 10);
      for (final msg in historyAfterSync) {
        final meta = _extractMetadataFromMessage(msg);
        if (meta != null) return meta;
      }
    }

    _log('Metadata not found after 3 checks (Pinned, History, 2x Sync).');
    return null;
  }

  Future<void> healMetadata({
    required int channelId,
    required String mnemonic,
    required String password,
  }) async {
    _log('Cloud empty but Local Mnemonic found. Running healMetadata...');
    final mnemonicBytes = CryptoUtils.mnemonicToBytes(mnemonic);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final iv = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
    
    final key = await CryptoUtils.pbkdf2Async(
      password: password,
      salt: salt,
      iterations: 600000,
    );
    
    final encMnemonic = CryptoUtils.aesGcmEncrypt(mnemonicBytes, key, iv);
    if (encMnemonic != null) {
      final identityHash = computeIdentityHash(mnemonic, (await _telegram.getMe()));
      await setCloudMetadata(
        channelId: channelId,
        epoch: timestamp,
        saltHex: hex.encode(salt),
        ivHex: hex.encode(iv),
        encMnemonicHex: hex.encode(encMnemonic),
        identityHash: identityHash,
      );
      
      _log('Verifying healed metadata is readable...');
      final verification = await getCloudMetadata(channelId);
      if (verification == null) {
        _log('HEAL VERIFICATION FAILED: Metadata not readable after write.');
        throw Exception('Metadata healing failed verification — data not readable after pin.');
      }
      _log('Atomic Anchor RE-ESTABLISHED and VERIFIED.');
    } else {
      _log('HEAL FAILED: AES-GCM encryption returned null.');
      throw Exception('Metadata healing failed — encryption error.');
    }
  }

  Future<Map<String, dynamic>?> _getChatPinnedMessage(int chatId) async {
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;
    final extra = 'nebula_getPinned_$chatId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (update['@type'] == 'message') {
        if (!completer.isCompleted) completer.complete(update);
      } else {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    _telegram.send({
      '@type': 'getChatPinnedMessage',
      'chat_id': chatId,
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () => null);
  }

  Map<String, String>? _extractMetadataFromMessage(Map<String, dynamic>? message) {
    if (message == null) return null;
    final text = message['content']?['text']?['text'] as String? ?? '';
    if (!text.startsWith(_metaPrefix)) return null;

    final parts = text.substring(_metaPrefix.length).split('|');
    final result = <String, String>{};
    for (final part in parts) {
      final kv = part.split(':');
      if (kv.length == 2) {
        result[kv[0]] = kv[1];
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _getChatHistory(int chatId, {int limit = 20}) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    StreamSubscription? sub;
    final extra = 'nebula_getHistory_$chatId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (update['@type'] == 'messages') {
        final messages = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (!completer.isCompleted) completer.complete(messages);
      } else {
        if (!completer.isCompleted) completer.complete([]);
      }
    });

    _telegram.send({
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'from_message_id': 0,
      'offset': 0,
      'limit': limit,
      'only_local': false,
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () => []);
  }


  Future<int?> ensureAnchor({
    String? mnemonic,
    int? tgUserId,
    String? password,
    bool isNewVault = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedId = prefs.getInt('vault_channel_id');

    if (cachedId != null && mnemonic == null && !isNewVault) {
      _log('[VaultAnchor] Background check healthy. Skipping redundant discovery.');
      return cachedId;
    }

    int? effectiveTgId = tgUserId;
    if (effectiveTgId == null) {
      try {
        _log('[VaultAnchor] TG User ID missing for anchor check. Fetching...');
        effectiveTgId = await _telegram.getMe();
      } catch (e) {
        _log('[VaultAnchor] Discovery Gap: Cannot proceed without Telegram ID ($e)');
        return cachedId; 
      }
    }

    final String currentHash;
    if (mnemonic != null && effectiveTgId != null) {
      currentHash = computeIdentityHash(mnemonic, effectiveTgId);
    } else {
      currentHash = (getLocalIdentityHash() as String?) ?? ''; 
    }

    int? channelId = await findNebulaChannel(expectedHash: currentHash.isEmpty ? null : currentHash);

    if (channelId != null) {
      _log('Found existing "$_channelName" channel: $channelId');
      
      if (mnemonic != null) {
        final currentHash = computeIdentityHash(mnemonic, effectiveTgId);
        final anchoredHash = await getHashFromDescription(channelId);
        final isHashMismatch = anchoredHash == null || anchoredHash.isEmpty || anchoredHash != currentHash;

        if (isHashMismatch) {
          _log('Hash Mismatch detected (Anchored=$anchoredHash, Current=$currentHash).');
          _log('Start Fresh/Restoration Bypass: Reusing existing channel and overwriting IdentityHash.');
          await setHashInDescription(channelId, currentHash);
        }

        if (password != null) {
          _log('[VaultAnchor] Syncing fresh cloud metadata to existing channel.');
          await healMetadata(
            channelId: channelId,
            mnemonic: mnemonic,
            password: password,
          );
        }
      }
      return channelId;
    } else {
      if (mnemonic != null) {
        _log('No "$_channelName" channel found — creating fresh...');
        final currentHash = computeIdentityHash(mnemonic, effectiveTgId);
        channelId = await createNebulaChannel();
        await setHashInDescription(channelId, currentHash);
        
        if (password != null) {
          await healMetadata(channelId: channelId, mnemonic: mnemonic, password: password);
        }
        return channelId;
      }
    }
    return null;
  }

  Future<void> setHashInDescription(int channelId, String identityHash) async {
    await waitForTelegramReady();
    _log('Setting anchored Identity Hash in description: $identityHash');

    final description = '$_hashPrefix$identityHash';
    final completer = Completer<void>();
    StreamSubscription? sub;
    const extra = 'nebula_setDesc';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();
      if (!completer.isCompleted) completer.complete();
    });

    _telegram.send({
      '@type': 'setChatDescription',
      'chat_id': channelId,
      'description': description,
      '@extra': extra,
    });

    await completer.future.timeout(const Duration(seconds: 10));
    _log('[VaultAnchor] Description set and verified to: $description');
  }

  Future<String?> getHashFromDescription(int channelId) async {
    final result = await _fetchSupergroupHash(channelId);
    if (result != null) return result;
    
    _log('Standard supergroup lookup failed for $channelId. Trying chat-based ID extraction...');
    try {
      final chat = await _getChat(channelId);
      if (chat != null) {
        final chatType = chat['type'] as Map<String, dynamic>?;
        if (chatType != null && chatType['@type'] == 'chatTypeSupergroup') {
          final realSupergroupId = chatType['supergroup_id'] as int?;
          if (realSupergroupId != null) {
            _log('Extracted real supergroup_id=$realSupergroupId from chat $channelId. Retrying...');
            return await _fetchSupergroupHashById(realSupergroupId);
          }
        }
      }
    } catch (e) {
      _log('Chat-based ID extraction failed: $e');
    }
    return null;
  }

  Future<String?> _fetchSupergroupHash(int channelId) async {
    String idStr = channelId.toString();
    if (idStr.startsWith('-100')) {
      final rawId = int.tryParse(idStr.substring(4));
      if (rawId != null) return _fetchSupergroupHashById(rawId);
    }
    final supergroupId = channelId > 0 ? -channelId : channelId;
    return _fetchSupergroupHashById(supergroupId);
  }

  Future<String?> _fetchSupergroupHashById(int supergroupId) async {
    final completer = Completer<String?>();
    StreamSubscription? sub;
    final extra = 'nebula_getSGFullInfo_hash_$supergroupId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();

      if (update['@type'] == 'supergroupFullInfo') {
        final description = update['description'] as String? ?? '';
        if (description.startsWith(_hashPrefix)) {
          final content = description.substring(_hashPrefix.length);
          final hash = content.split(_epochSeparator)[0];
          if (!completer.isCompleted) completer.complete(hash);
        } else {
          if (!completer.isCompleted) completer.complete(null);
        }
      } else if (update['@type'] == 'error') {
        final message = update['message'] as String? ?? '';
        final code = update['code'] as int? ?? 0;
        
        _log('getSupergroup error ($code) for sg_id=$supergroupId: $message. Attempting getChat fallback...');
        
        final convertedChatId = int.tryParse('-100$supergroupId');
        if (convertedChatId != null) {
          _getChat(convertedChatId).then((chat) {
            if (chat != null && !completer.isCompleted) {
               _log('Fallback: Chat $convertedChatId exists. Calling getHashFromDescription bypass.');
               completer.complete(null); 
            } else if (!completer.isCompleted) {
               completer.complete(null);
            }
          });
          return;
        }
        
        if (!completer.isCompleted) completer.complete(null);
      } else {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    _telegram.send({
      '@type': 'getSupergroupFullInfo',
      'supergroup_id': supergroupId,
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      sub?.cancel();
      _log('Timeout fetching supergroup info for sg_id=$supergroupId');
      return null;
    });
  }


  Future<void> saveLocalAnchor({int? epoch, String? identityHash}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (epoch != null) await prefs.setInt('vault_epoch', epoch);
      if (identityHash != null) {
        await prefs.setString('vault_identity_hash', identityHash);
      }
      _log('Saved local anchor: Epoch=$epoch, Hash=${identityHash?.substring(0, 8)}...');
    } catch (e) {
      _log('Failed to save local anchor: $e');
    }
  }

  Future<String?> getLocalIdentityHash() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('vault_identity_hash');
    } catch (e) {
      _log('Failed to get local identity hash: $e');
      return null;
    }
  }

  Future<int> getLocalEpoch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('vault_epoch') ?? 0;
    } catch (e) {
      _log('Failed to get local epoch: $e');
      return 0;
    }
  }

  Future<void> clearLocalAnchor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('vault_epoch');
      await prefs.remove('vault_identity_hash');
      await prefs.remove('vault_channel_id');
      _log('Local anchor data cleared.');
    } catch (e) {
      _log('Failed to clear local anchor: $e');
    }
  }

  Future<bool> isVaultOutdated() async {
    _log('Checking if vault is outdated (epoch sync)...');
    final channelId = await findNebulaChannel();
    if (channelId == null) return false;

    final metadata = await getCloudMetadata(channelId);
    if (metadata == null) return false;

    final cloudEpoch = int.tryParse(metadata['Epoch'] ?? '0') ?? 0;
    final localEpoch = await getLocalEpoch();
    _log('Epoch Check: Cloud=$cloudEpoch, Local=$localEpoch');

    return cloudEpoch > localEpoch;
  }

  Future<bool> detectExistingVault() async {
    _log('Detecting existing vault (Pivot to Metadata)...');
    final channelId = await findNebulaChannel();
    if (channelId == null) return false;

    final metadata = await getCloudMetadata(channelId);
    return metadata != null;
  }

  Future<RestorationGuardResult> restorationGuard(String mnemonic, int tgUserId) async {
    _log('Running Restoration Guard for user $tgUserId...');
    try {
      final channelId = await findNebulaChannel();
      if (channelId == null) return RestorationGuardResult.noAnchor;

      final anchoredHash = await getHashFromDescription(channelId);
      if (anchoredHash == null) return RestorationGuardResult.noAnchor;

      final expectedHash = computeIdentityHash(mnemonic, tgUserId);
      if (anchoredHash == expectedHash) {
        _log('Restoration Guard: MATCH');
        return RestorationGuardResult.match;
      } else {
        _log('Restoration Guard: MISMATCH');
        return RestorationGuardResult.mismatch;
      }
    } catch (e) {
      _log('Restoration Guard: ERROR — $e');
      return RestorationGuardResult.error;
    }
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[VaultAnchor] $message');
    }
  }
}

enum RestorationGuardResult { match, mismatch, noAnchor, error }
