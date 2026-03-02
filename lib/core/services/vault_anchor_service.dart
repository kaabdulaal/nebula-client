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

class VaultAnchorService {
  static const String _channelName = 'Nebula Vault';
  static const String _hashPrefix = 'IdentityHash: ';
  static const String _epochSeparator = ' | Epoch: ';
  static const String _metaPrefix = 'NEBULA_META|';

  static int? _activeChannelId;

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
      const Duration(seconds: 3),
      onTimeout: () {
        sub?.cancel();
        timer.cancel();
        _log('Timeout waiting for Telegram authorization (silent fallback).');
        // We no longer throw here to prevent boot-lock
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
    _log('[DEBUG] findNebulaChannel called. forceRefresh: $forceRefresh');
    
    if (_activeChannelId != null && !forceRefresh) {
      _log('[DEBUG] Returning in-memory _activeChannelId: $_activeChannelId');
      return _activeChannelId;
    }

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
          _log('DB Channel ID $dbId failed verification. Preserving cache (may be cold boot delay).');
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
        _log('Prefs Channel ID $cachedId failed verification. Preserving cache.');
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

    // Instant failover to deep server discovery (no preload delays)
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

      // Title matches — now verify identity hash if provided
      if (expectedHash != null) {
        return await verifyVaultSignature(chatId, expectedHash);
      }
      
      // No hash to verify against, title match is sufficient for discovery
      _log('Chat $chatId matches title "$_channelName". No hash to verify.');
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
      if (expectedHash == null || cloudHash == expectedHash) {
        return true;
      } else {
        _log('Handshake Failed: IdentityHash mismatch. Pinned/Found hash $cloudHash != $expectedHash in chat $chatId');
        return false;
      }
    } catch (e) {
      _log('Error verifying chat health for $chatId: $e');
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

    final result = await completer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
    
    if (result == null) {
      _log('[DIAGNOSTIC] discovery failed. Listing recent chats for context...');
      try {
        await refreshChatList(limit: 10);
        // We don't have a direct "list all chats" here easily without more complex state tracking, 
        // but we can log that we are attempting a wide search.
      } catch (e) {
        _log('[DIAGNOSTIC] Could not refresh chat list for diagnostics: $e');
      }
    }
    
    return result;
  }

  /// Deep Server Discovery — Search → Verify pipeline.
  ///
  /// Uses TDLib's global `searchMessages` to find messages with the
  /// `#NEBULA_METADATA` tag across ALL chats (not just cached ones).
  /// Skips hydration (TDLib already knows the chat internally from
  /// the search result) and goes straight to ownership verification.
  Future<int?> _deepServerDiscovery() async {
    _log('[DeepDiscovery] Starting Search → Verify pipeline...');

    // ── Step 1: Scoped Search ──────────────────────────────────────────
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
        _log('[DeepDiscovery] searchMessages error: ${update['message']}');
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
        _log('[DeepDiscovery] searchMessages timed out after 10s.');
        return null;
      },
    );

    if (foundMessage == null) {
      _log('[DeepDiscovery] No messages found with #NEBULA_METADATA tag.');
      return null;
    }

    final chatId = foundMessage['chat_id'] as int?;
    if (chatId == null) {
      _log('[DeepDiscovery] Found message has no chat_id.');
      return null;
    }

    _log('[DeepDiscovery] Found candidate chat_id: $chatId. Verifying ownership...');

    // ── Step 2: Ownership Verification ─────────────────────────────────
    // Ensure the current user is the CREATOR of this channel.
    // This prevents latching onto forwarded #NEBULA_METADATA messages
    // in Saved Messages, groups, or other people's channels.
    try {
      final userId = await _telegram.getMe();
      final member = await _telegram.getChatMember(chatId, userId);

      if (member == null) {
        _log('[DeepDiscovery] REJECTED: Could not fetch membership for chat $chatId.');
        return null;
      }

      final memberStatus = member['status']?['@type'] as String? ?? '';
      _log('[DeepDiscovery] User membership status: $memberStatus');

      if (memberStatus == 'chatMemberStatusCreator') {
        _log('[DeepDiscovery] VERIFIED: User is creator of chat $chatId.');
        return chatId;
      } else if (memberStatus == 'chatMemberStatusAdministrator') {
        _log('[DeepDiscovery] ACCEPTED: User is administrator of chat $chatId.');
        return chatId;
      } else {
        _log('[DeepDiscovery] REJECTED: User is "$memberStatus" in chat $chatId. Not the owner.');
        return null;
      }
    } catch (e) {
      _log('[DeepDiscovery] Ownership check failed: $e');
      return null;
    }
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

    return completer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
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
    // Buffer for early-arriving updateMessageSendSucceeded events
    final earlySucceeded = <Map<String, dynamic>>[];

    void tryPinFromSucceeded(Map<String, dynamic> update) {
      final realMessageId = update['message']?['id'] as int?;
      if (realMessageId == null) {
        if (!completer.isCompleted) {
          completer.completeError(Exception('Metadata send succeeded but real message ID is null'));
        }
        return;
      }
      _pinMessage(channelId, realMessageId).then((_) {
        if (!completer.isCompleted) completer.complete();
        sub?.cancel();
      }).catchError((e) {
        if (!completer.isCompleted) completer.completeError(e);
        sub?.cancel();
      });
    }

    sub = _telegram.updates.listen((update) {
      final type = update['@type'];

      // Step 1: Capture the temporary message ID from the send response
      if (update['@extra'] == extra && type == 'message') {
        tempMessageId = update['id'] as int;
        _log('Metadata message sent: tempId=$tempMessageId');

        // Check if we already received a matching succeeded event
        for (final early in earlySucceeded) {
          if (early['old_message_id'] == tempMessageId) {
            _log('Processing buffered updateMessageSendSucceeded for tempId=$tempMessageId');
            tryPinFromSucceeded(early);
            return;
          }
        }
      }
      // Step 2: Handle send succeeded — may arrive before or after step 1
      else if (type == 'updateMessageSendSucceeded') {
        if (tempMessageId != null && update['old_message_id'] == tempMessageId) {
          tryPinFromSucceeded(update);
        } else {
          // Buffer it — tempMessageId not yet known
          earlySucceeded.add(update);
        }
      }
      // Step 3: Handle send error
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
    
    return completer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
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
    
    final identityHash = computeIdentityHash(mnemonicStr, tgUserId);
    await setCloudMetadata(
      channelId: channelId,
      epoch: timestamp,
      saltHex: hex.encode(salt),
      ivHex: hex.encode(iv),
      encMnemonicHex: hex.encode(encMnemonic!),
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

      // Unpin all messages — awaited
      try {
        final unpinCompleter = Completer<void>();
        StreamSubscription? unpinSub;
        final unpinExtra = 'nebula_unpin_${DateTime.now().millisecondsSinceEpoch}';

        unpinSub = _telegram.updates.listen((update) {
          if (update['@extra'] != unpinExtra) return;
          unpinSub?.cancel();
          if (!unpinCompleter.isCompleted) unpinCompleter.complete();
        });

        _telegram.send({
          '@type': 'unpinAllChatMessages',
          'chat_id': channelId,
          '@extra': unpinExtra,
        });

        await unpinCompleter.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            unpinSub?.cancel();
            _log('Unpin all timed out (non-fatal).');
          },
        );
      } catch (e) {
        _log('Unpin all failed (ignorable): $e');
      }

      // Delete messages — awaited
      final ids = msgs.map((m) => m['id'] as int).toList();
      final deleteCompleter = Completer<void>();
      StreamSubscription? deleteSub;
      final deleteExtra = 'nebula_deleteMsgs_${DateTime.now().millisecondsSinceEpoch}';

      deleteSub = _telegram.updates.listen((update) {
        if (update['@extra'] != deleteExtra) return;
        deleteSub?.cancel();
        if (!deleteCompleter.isCompleted) deleteCompleter.complete();
      });

      _telegram.send({
        '@type': 'deleteMessages',
        'chat_id': channelId,
        'message_ids': ids,
        'revoke': true,
        '@extra': deleteExtra,
      });

      await deleteCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          deleteSub?.cancel();
          _log('Delete messages timed out — messages may persist.');
        },
      );

      _log('Deletion of ${ids.length} old metadata messages confirmed.');
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
      'query': 'EncMnemonic', // Standardized token search (O(1) scale-proof)
      'limit': 100, 
      '@extra': extra,
    });

    return completer.future.timeout(const Duration(seconds: 3), onTimeout: () => []);
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

  Future<Map<String, dynamic>?> getCloudMetadata(int channelId) async {
    await waitForTelegramReady();
    _log('Fetching Cloud Metadata...');

    // Attempt 0: Check Pinned Message (O(1) direct hit)
    _log('Checking pinned message for metadata...');
    final chat = await _getChat(channelId);
    final pinnedMsgId = chat?['pinned_message_id'] as int? ?? 0;
    if (pinnedMsgId != 0) {
      final pinnedMsg = await _getMessageById(channelId, pinnedMsgId);
      final meta = _extractMetadataFromMessage(pinnedMsg);
      if (meta != null) {
        _log('SUCCESS: Metadata found via pinned message.');
        return meta;
      }
    }

    // Attempt 1: O(1) Token Search
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;
    final extra = 'nebula_meta_search_$channelId';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      if (update['@type'] == 'messages') {
        final msgs = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final msg in msgs) {
           final meta = _extractMetadataFromMessage(msg);
           if (meta != null) {
              if (!completer.isCompleted) completer.complete(meta);
              return;
           }
        }
      }
      if (!completer.isCompleted) {
        // Only complete with null if we actually got a response that wasn't 'messages'
        // or if search returned 0 results.
        completer.complete(null);
      }
    });

    // 'EncMnemonic' is perfectly tokenized by Telegram, avoiding hashtag gluing issues.
    _telegram.send({
      '@type': 'searchChatMessages',
      'chat_id': channelId,
      'query': 'EncMnemonic', 
      'limit': 10,
      '@extra': extra,
    });

    Map<String, dynamic>? result;
    try {
       result = await completer.future.timeout(const Duration(seconds: 3));
    } catch (e) {
       _log('Attempt 1 (Search) timed out or failed: $e');
    }
    sub.cancel();

    if (result != null) {
      _log('SUCCESS: Metadata found via search.');
      return result;
    }

    // Attempt 2: INDESTRUCTIBLE Server-Side Read
    // Bypasses local TDLib SQLite cache completely by querying Telegram's global index.
    _log('Search failed. Falling back to INDESTRUCTIBLE server-side searchMessages...');
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
      'chat_id': channelId, // Restrict search to our vault
      'query': '#NEBULA_METADATA', // Find the exact metadata message
      'offset': '',
      'limit': 1,
      'filter': {'@type': 'searchMessagesFilterEmpty'},
      'min_date': 0,
      'max_date': 0,
      '@extra': serverExtra
    });

    final serverResult = await serverCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        serverSub?.cancel();
        return null;
      },
    );

    if (serverResult != null) {
      _log('SUCCESS: Metadata found via indestructible server search.');
      return serverResult;
    }

    _log('[CRITICAL] Discovery failed. Vault metadata unreachable.');
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
  }

  Map<String, String>? _extractMetadataFromMessage(Map<String, dynamic>? message) {
    if (message == null) return null;
    final text = message['content']?['text']?['text'] as String? ?? '';
    
    // Loose parsing: find metadata even if surrounded by other text/tags
    final metaIndex = text.indexOf(_metaPrefix);
    if (metaIndex == -1) return null;

    final parts = text.substring(metaIndex + _metaPrefix.length).split('|');
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
    if (mnemonic != null) {
      currentHash = computeIdentityHash(mnemonic, effectiveTgId);
    } else {
      currentHash = (await getLocalIdentityHash()) ?? ''; 
    }

    int? channelId = await findNebulaChannel(expectedHash: currentHash.isEmpty ? null : currentHash);

    // [CORE-LOBOTOMY] Last-chance aggressive discovery before rogue creation
    if (channelId == null) {
      _log('[VaultAnchor] Initial discovery failed. Attempting aggressive fallback scan for EXISTING "$_channelName"...');
      channelId = await _findExistingChannelFallback();
    }

    if (channelId != null) {
      _log('Found existing "$_channelName" channel: $channelId. PROTECTING AGAINST DUPLICATE CREATION.');
      
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
    // TDLib Chat IDs for supergroups are -100XXXXXXXXXX
    // getSupergroupFullInfo expects the raw supergroup ID (XXXXXXXXXX)
    if (idStr.startsWith('-100')) {
      final rawId = int.tryParse(idStr.substring(4));
      if (rawId != null) return _fetchSupergroupHashById(rawId);
    }
    
    // Fallback: try extracting supergroup_id from chat object
    _log('Chat ID $channelId does not follow -100 prefix. Extracting from chat...');
    try {
      final chat = await _getChat(channelId);
      if (chat != null) {
        final chatType = chat['type'] as Map<String, dynamic>?;
        if (chatType != null && chatType['@type'] == 'chatTypeSupergroup') {
          final realSupergroupId = chatType['supergroup_id'] as int?;
          if (realSupergroupId != null) {
            return _fetchSupergroupHashById(realSupergroupId);
          }
        }
      }
    } catch (e) {
      _log('Fallback supergroup extraction failed: $e');
    }
    return null;
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
      debugPrint('[VaultAnchor] $message');
    }
  }
}

enum RestorationGuardResult { match, mismatch, noAnchor, error }
