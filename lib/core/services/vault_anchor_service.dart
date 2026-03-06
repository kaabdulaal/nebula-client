import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:convert/convert.dart';
import 'package:nebula_client/core/utils/crypto_utils.dart';
import '../api/nebula_api.dart';
import 'telegram_service.dart';

enum RestorationGuardResult { match, mismatch, noAnchor, error }

class VaultAnchorService {
  static const String _channelName = 'Nebula Vault';
  static const String _hashPrefix = 'IdentityHash: ';
  static const String _epochSeparator = ' | Epoch: ';
  static const String _metaPrefix = 'NEBULA_META|';

  static int? _activeChannelId;
  static Future<int?>? _discoveryFuture;

  final TelegramService _telegram;

  VaultAnchorService({TelegramService? telegramService})
      : _telegram = telegramService ?? TelegramService();

  Future<bool> checkChannelExistence(int chatId) async {
    try {
      final chat = await _getChat(chatId);
      if (chat == null) return false;
      return chat['title'] == _channelName;
    } catch (e) {
      return false;
    }
  }

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
      const Duration(seconds: 3),
      onTimeout: () {
        sub?.cancel();
        timer.cancel();
        _log('Timeout waiting for Telegram authorization (silent fallback).');
        return; 
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
    if (_activeChannelId != null && !forceRefresh) return _activeChannelId;
    if (_discoveryFuture != null && !forceRefresh) return _discoveryFuture;

    _discoveryFuture = _performDiscovery(forceRefresh: forceRefresh, expectedHash: expectedHash);
    try {
      final result = await _discoveryFuture;
      return result;
    } finally {
      if (!forceRefresh) _discoveryFuture = null;
    }
  }

  Future<int?> _performDiscovery({bool forceRefresh = false, String? expectedHash}) async {
    _log('[Discovery] Starting channel resolution. force: $forceRefresh');

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
            _activeChannelId = dbId;
            return dbId;
          }
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
          _activeChannelId = cachedId;
          return cachedId;
        }
      }
    }

    _log('Attempting fast local search...');
    final foundId = await _searchNebulaChat();
    
    if (foundId != null) {
      if (await _verifyChatHealthy(foundId, expectedHash)) {
        _log('Discovery SUCCESS: Found "$_channelName" at ID $foundId.');
        await prefs.setInt('vault_channel_id', foundId);
        if (NebulaApi.instance.isInitialized) {
          NebulaApi.instance.setSetting('vault_channel_id', foundId.toString());
        }
        _activeChannelId = foundId;
        return foundId;
      }
    }

    _log('Local search failed. Bypassing preload delays, going straight to Deep Discovery...');
    final deepId = await _deepServerDiscovery();
    if (deepId != null) {
      _log('Deep Discovery already verified ownership. TRUSTING ID: $deepId');
      await prefs.setInt('vault_channel_id', deepId);
      if (NebulaApi.instance.isInitialized) {
        NebulaApi.instance.setSetting('vault_channel_id', deepId.toString());
      }
      _activeChannelId = deepId;
      return deepId;
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
        return await verifyVaultSignature(chatId, expectedHash);
      }
      
      return true;
    } catch (e) {
      _log('Error verifying chat health for $chatId: $e');
      return false;
    }
  }

  Future<bool> verifyVaultSignature(int chatId, String? expectedHash) async {
    try {
      final metadata = await getCloudMetadata(chatId);
      if (metadata == null) {
        _log('Handshake Failed: No metadata found in chat $chatId');
        return false;
      }

      final cloudHash = metadata['IdentityHash'];
      return expectedHash == null || cloudHash == expectedHash;
    } catch (e) {
      _log('Error verifying chat signature for $chatId: $e');
      return false;
    }
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

    return await completer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
  }

  Future<int?> _deepServerDiscovery() async {
    _log('[DeepDiscovery] Starting Search → Verify pipeline...');

    final searchCompleter = Completer<Map<String, dynamic>?>();
    StreamSubscription? searchSub;
    final searchExtra = 'nebula_deepSearch_${DateTime.now().millisecondsSinceEpoch}';

    searchSub = _telegram.updates.listen((update) {
      if (update['@extra'] != searchExtra) return;
      searchSub?.cancel();

      if (update['@type'] == 'foundMessages') {
        final messages = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (messages.isNotEmpty) {
          if (!searchCompleter.isCompleted) searchCompleter.complete(messages.first);
        } else {
          if (!searchCompleter.isCompleted) searchCompleter.complete(null);
        }
      } else if (update['@type'] == 'error') {
        if (!searchCompleter.isCompleted) searchCompleter.complete(null);
      } else {
        if (!searchCompleter.isCompleted) searchCompleter.complete(null);
      }
    });

    _telegram.send({
      '@type': 'searchMessages',
      'query': '#NEBULA_METADATA',
      'offset': '',
      'limit': 5,
      'filter': {'@type': 'searchMessagesFilterEmpty'},
      'min_date': 0,
      'max_date': 0,
      '@extra': searchExtra,
    });

    final foundMessage = await searchCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        searchSub?.cancel();
        return null;
      },
    );

    if (foundMessage == null) return null;

    final chatId = foundMessage['chat_id'] as int?;
    if (chatId == null) return null;

    try {
      final userId = await _telegram.getMe();
      final member = await _telegram.getChatMember(chatId, userId);

      if (member == null) return null;

      final memberStatus = member['status']?['@type'] as String? ?? '';
      if (memberStatus == 'chatMemberStatusCreator' || memberStatus == 'chatMemberStatusAdministrator') {
        return chatId;
      }
    } catch (e) {
      _log('[DeepDiscovery] Ownership check failed: $e');
    }
    return null;
  }

  Future<bool> canUpload(int chatId) async {
    try {
      final chat = await _getChat(chatId);
      if (chat == null) return false;

      final type = chat['type']?['@type'];
      if (type == 'chatTypeSupergroup') {
        final userId = await _telegram.getMe();
        final member = await _telegram.getChatMember(chatId, userId);
        final memberStatus = member?['status']?['@type'];
        
        if (memberStatus == 'chatMemberStatusCreator') return true;

        final permissions = chat['permissions'] as Map?;
        final canSendMessages = permissions?['can_send_messages'] ?? true;
        final canSendDocs = permissions?['can_send_documents'] ?? true;
        
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
      const Duration(seconds: 3),
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
        if (!completer.isCompleted) completer.complete(null);
      } else {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    _telegram.send({
      '@type': 'getChat',
      'chat_id': chatId,
      '@extra': extra,
    });

    return await completer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
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
        sub?.cancel();
        _findExistingChannelFallback().then((existingId) {
          if (existingId != null && !completer.isCompleted) {
            completer.complete(existingId);
          } else if (!completer.isCompleted) {
            completer.completeError(Exception('createNebulaChannel failed'));
          }
        }).catchError((e) {
          if (!completer.isCompleted) completer.completeError(e);
        });
      }
    });

    _telegram.send({
      '@type': 'createNewSupergroupChat',
      '@extra': extra,
      'title': _channelName,
      'is_channel': true,
      'description': '', 
      'for_import': false,
    });

    return await completer.future.timeout(const Duration(seconds: 15), onTimeout: () async {
      sub?.cancel();
      final existingId = await _findExistingChannelFallback();
      if (existingId != null) return existingId;
      throw TimeoutException('Channel creation timed out');
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
    
    final anchoredHash = await getHashFromDescription(channelId);
    if (anchoredHash != null && anchoredHash.isNotEmpty && anchoredHash != identityHash) {
      _log('[SECURITY] CRITICAL: Identity Guard Blocked Metadata Overwrite!');
      throw Exception('Identity Mismatch: Cannot overwrite existing cloud vault.');
    }

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
      if (update['@extra'] == extra && update['@type'] == 'message') {
        tempMessageId = update['id'] as int;
      }
      else if (update['@type'] == 'updateMessageSendSucceeded') {
        if (tempMessageId != null && update['old_message_id'] == tempMessageId) {
          final realId = update['message']?['id'] as int?;
          if (realId != null) {
            _pinMessage(channelId, realId).then((_) {
              if (!completer.isCompleted) completer.complete();
              sub?.cancel();
            });
          }
        }
      }
      else if (update['@extra'] == extra && update['@type'] == 'error') {
        if (!completer.isCompleted) completer.completeError(Exception('Metadata send failed'));
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
  }

  Future<Map<String, dynamic>?> getCloudMetadata(int channelId) async {
    await waitForTelegramReady();

    final chat = await _getChat(channelId);
    final pinnedMsgId = chat?['pinned_message_id'] as int? ?? 0;
    if (pinnedMsgId != 0) {
      final pinnedMsg = await _getMessageById(channelId, pinnedMsgId);
      final meta = _extractMetadataFromMessage(pinnedMsg);
      if (meta != null) return meta;
    }

    final serverCompleter = Completer<Map<String, dynamic>?>();
    StreamSubscription? serverSub;
    final serverExtra = 'nebula_meta_rescue_${DateTime.now().millisecondsSinceEpoch}';

    serverSub = _telegram.updates.listen((update) {
      if (update['@extra'] != serverExtra) return;
      serverSub?.cancel();

      if (update['@type'] == 'foundMessages') {
        final messages = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final msg in messages) {
           final meta = _extractMetadataFromMessage(msg);
           if (meta != null) {
              if (!serverCompleter.isCompleted) serverCompleter.complete(meta);
              return;
           }
        }
      }
      if (!serverCompleter.isCompleted) serverCompleter.complete(null);
    });

    _telegram.send({
      '@type': 'searchMessages',
      'chat_id': channelId, 
      'query': '#NEBULA_METADATA', 
      'offset': '',
      'limit': 1,
      'filter': {'@type': 'searchMessagesFilterEmpty'},
      'min_date': 0,
      'max_date': 0,
      '@extra': serverExtra
    });

    return await serverCompleter.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
  }

  Map<String, String>? _extractMetadataFromMessage(Map<String, dynamic>? message) {
    if (message == null) return null;
    final content = message['content'];
    if (content == null || content['@type'] != 'messageText') return null;
    final text = content['text']?['text'] as String? ?? '';
    
    final metaIndex = text.indexOf(_metaPrefix);
    if (metaIndex == -1) return null;

    final parts = text.substring(metaIndex + _metaPrefix.length).split('|');
    final result = <String, String>{};
    for (final part in parts) {
      final kv = part.split(':');
      if (kv.length == 2) result[kv[0]] = kv[1];
    }
    return result;
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
    
    return await completer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
  }

  Future<void> cleanupCloudMetadata(int channelId) async {
    try {
      final msgs = await _searchAllMetadataMessages(channelId);
      if (msgs.isEmpty) return;

      final ids = msgs.map((m) => m['id'] as int).toList();
      final deleteExtra = 'nebula_deleteMsgs_${DateTime.now().millisecondsSinceEpoch}';

      _telegram.send({
        '@type': 'deleteMessages',
        'chat_id': channelId,
        'message_ids': ids,
        'revoke': true,
        '@extra': deleteExtra,
      });
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
      'query': 'EncMnemonic', 
      'limit': 100, 
      '@extra': extra,
    });

    return await completer.future.timeout(const Duration(seconds: 3), onTimeout: () => []);
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

    return await completer.future.timeout(const Duration(seconds: 10));
  }

  Future<int?> ensureAnchor({
    String? mnemonic,
    int? tgUserId,
    String? password,
    bool isNewVault = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedId = prefs.getInt('vault_channel_id');

    if (cachedId != null && mnemonic == null && !isNewVault) return cachedId;

    int? effectiveTgId = tgUserId ?? await _telegram.getMe();
    if (effectiveTgId == null) return cachedId;

    final String currentHash;
    if (mnemonic != null) {
      currentHash = computeIdentityHash(mnemonic, effectiveTgId);
    } else {
      currentHash = (await getLocalIdentityHash()) ?? ''; 
    }

    int? channelId = await findNebulaChannel(expectedHash: currentHash.isEmpty ? null : currentHash);
    if (channelId == null) channelId = await _findExistingChannelFallback();

    if (channelId != null) {
      if (mnemonic != null) {
        final anchoredHash = await getHashFromDescription(channelId);
        if (anchoredHash != null && anchoredHash.isNotEmpty && anchoredHash != currentHash) {
          throw Exception('Identity Mismatch: Cannot overwrite existing cloud vault.');
        }
        await setHashInDescription(channelId, currentHash);
      }
      return channelId;
    } else if (mnemonic != null) {
      channelId = await createNebulaChannel();
      await setHashInDescription(channelId, currentHash);
      return channelId;
    }
    return null;
  }

  Future<void> setHashInDescription(int channelId, String identityHash) async {
    await waitForTelegramReady();
    final description = '$_hashPrefix$identityHash';
    final completer = Completer<void>();
    StreamSubscription? sub;
    const extra = 'nebula_setDesc';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] == extra) {
        sub?.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    });

    _telegram.send({
      '@type': 'setChatDescription',
      'chat_id': channelId,
      'description': description,
      '@extra': extra,
    });

    await completer.future.timeout(const Duration(seconds: 10));
  }

  Future<String?> getHashFromDescription(int channelId) async {
    final chat = await _getChat(channelId);
    if (chat == null) return null;
    final type = chat['type'];
    if (type == null || type['@type'] != 'chatTypeSupergroup') return null;
    
    final supergroupId = type['supergroup_id'] as int?;
    if (supergroupId == null) return null;

    final completer = Completer<String?>();
    StreamSubscription? sub;
    final extra = 'nebula_getHash_$supergroupId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] == extra) {
        sub?.cancel();
        if (update['@type'] == 'supergroupFullInfo') {
          final desc = update['description'] as String? ?? '';
          if (desc.startsWith(_hashPrefix)) {
            if (!completer.isCompleted) completer.complete(desc.substring(_hashPrefix.length).split(' ')[0]);
          } else {
            if (!completer.isCompleted) completer.complete(null);
          }
        } else {
          if (!completer.isCompleted) completer.complete(null);
        }
      }
    });

    _telegram.send({
      '@type': 'getSupergroupFullInfo',
      'supergroup_id': supergroupId,
      '@extra': extra,
    });

    return await completer.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
  }

  Future<void> saveLocalAnchor({int? epoch, String? identityHash}) async {
    final prefs = await SharedPreferences.getInstance();
    if (epoch != null) await prefs.setInt('vault_epoch', epoch);
    if (identityHash != null) await prefs.setString('vault_identity_hash', identityHash);
  }

  Future<String?> getLocalIdentityHash() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('vault_identity_hash');
  }

  Future<int> getLocalEpoch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('vault_epoch') ?? 0;
  }

  Future<void> clearLocalAnchor() async {
    _log('Clearing local anchor state (RAM and Disk)...');
    _activeChannelId = null;
    _discoveryFuture = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('vault_epoch');
    await prefs.remove('vault_identity_hash');
    await prefs.remove('vault_channel_id');
  }

  Future<bool> detectExistingVault() async {
    final channelId = await findNebulaChannel();
    if (channelId == null) return false;
    final metadata = await getCloudMetadata(channelId);
    return metadata != null;
  }

  Future<RestorationGuardResult> restorationGuard(String mnemonic, int tgUserId) async {
    try {
      final channelId = await findNebulaChannel();
      if (channelId == null) return RestorationGuardResult.noAnchor;

      final anchoredHash = await getHashFromDescription(channelId);
      if (anchoredHash == null) return RestorationGuardResult.noAnchor;

      final expectedHash = computeIdentityHash(mnemonic, tgUserId);
      return (anchoredHash == expectedHash) ? RestorationGuardResult.match : RestorationGuardResult.mismatch;
    } catch (e) {
      return RestorationGuardResult.error;
    }
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[VaultAnchor] $message');
  }
}
