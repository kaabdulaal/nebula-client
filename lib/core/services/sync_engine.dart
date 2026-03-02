import 'dart:async';
import 'dart:isolate';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../api/nebula_api.dart';
import '../models/file_node.dart';
import '../../features/transfers/download_orchestrator.dart';
import 'telegram_service.dart';
import 'vault_anchor_service.dart';
import '../utils/crypto_utils.dart';

class SyncEngine extends ChangeNotifier {
  static final SyncEngine _instance = SyncEngine._internal();
  factory SyncEngine() => _instance;

  final TelegramService _telegram;
  final VaultAnchorService _anchor;
  final NebulaApi _api;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  bool _showGlobalProgress = false;
  bool get showGlobalProgress => _showGlobalProgress;

  Uint8List? _masterKey;
  int? _myUserId;
  StreamSubscription? _updateSub;
  final Map<String, DateTime> _lastGhostPurgeTimes = {};
  
  Timer? _autoPushTimer;

  /// Callback fired when a sync threat is detected (VMK mismatch / decryption failure).
  /// The AuthNotifier should listen to this and force a session invalidation.
  void Function(String reason)? onSyncThreat;

  SyncEngine._internal({
    TelegramService? telegramService,
    VaultAnchorService? vaultAnchorService,
    NebulaApi? nebulaApi,
  })  : _telegram = telegramService ?? TelegramService(),
        _anchor = vaultAnchorService ?? VaultAnchorService(),
        _api = nebulaApi ?? NebulaApi.instance;

  @visibleForTesting
  SyncEngine.withMocks({
    required TelegramService telegramService,
    required VaultAnchorService vaultAnchorService,
    required NebulaApi nebulaApi,
  })  : _telegram = telegramService,
        _anchor = vaultAnchorService,
        _api = nebulaApi;

  void setMasterKey(Uint8List key) {
    _masterKey = Uint8List.fromList(key);
    _log('[SECURITY] Master Vault Key (VMK) locked and loaded.');
  }

  bool get isSecurityHardened => _masterKey != null;

  /// Returns a copy of the current master key, or null if not set.
  Uint8List? get masterKeySnapshot => _masterKey != null ? Uint8List.fromList(_masterKey!) : null;

  Future<void> initializeRealTimeListener() async {
    if (_updateSub != null) return;
    
    _log('[SYNC] Initializing Real-time Sync Listener...');
    
    // 1. Get my User ID for deduplication
    try {
      _myUserId = await _telegram.getMe();
      _log('[SYNC] My User ID: $_myUserId');
    } catch (e) {
      _log('[SYNC] Warning: Could not fetch my User ID. All messages will be applied.');
    }

    final chatId = await _anchor.findNebulaChannel();
    if (chatId == null) {
      _log('[SYNC] Error: No vault channel found. Listener aborted.');
      return;
    }

    _updateSub = _telegram.updates.listen((update) {
      if (update['@type'] == 'updateNewMessage') {
        final message = update['message'] as Map<String, dynamic>;
        if (message['chat_id'] != chatId) return;

        // Deduplication: Ignore if I sent it
        final sender = message['sender_id'];
        if (sender != null && sender['@type'] == 'messageSenderUser') {
          if (sender['user_id'] == _myUserId) {
            _log('[SYNC] Ignoring self-message: ${message['id']}');
            return;
          }
        }

        final content = message['content'];
        if (content == null) return;

        final text = content['text']?['text'] as String? ?? '';
        final caption = content['caption']?['text'] as String? ?? '';
        
        final meta = text.isEmpty ? caption : text;

        final date = message['date'] as int? ?? 0;

        if (meta.contains('#NEBULA_TOMBSTONE')) {
           _log('[REALTIME] Tombstone detected: ${message['id']}. Applying delta...');
           _applyTombstone(meta, date);
        } else if (meta.contains('#NEBULA_MANIFEST')) {
           _log('[REALTIME] Manifest detected: ${message['id']}. Applying delta...');
           _applyManifest(meta, date);
        }
      }
    });

    _log('[SYNC] Real-time Listener active for channel $chatId');
  }

  void _applyTombstone(String meta, int timestamp) {
    try {
      // Format: #NEBULA_TOMBSTONE|Path:ID OR #NEBULA_TOMBSTONE|ids:id1,id2,id3
      final parts = meta.split('|');
      if (parts.length < 2) return;
      
        final payload = parts[1];
        if (payload.startsWith('ids:')) {
          final idsStr = payload.substring(4);
          final ids = idsStr.split(',');
          _log('[DELTA] Applying bulk DELETE for ${ids.length} items...');
          for (final id in ids) {
            final trimmedId = id.trim();
            final cleanId = trimmedId.startsWith('[DELETED]:') 
                ? trimmedId.substring(10) 
                : trimmedId;
            _api.deleteItem(cleanId, timestamp: timestamp);
          }
        } else {
          // Handle both old format (ID) and new format ([DELETED]:ID)
          final cleanId = payload.startsWith('[DELETED]:') 
              ? payload.substring(10) 
              : (payload.contains(':') ? payload.split(':').last : payload);
          
          _api.deleteItem(cleanId, timestamp: timestamp);
      _log('[DELTA] Applied remote DELETE (LWW) for item: $cleanId');
    }
    } catch (e) {
      _log('[DELTA] Failed to apply tombstone: $e');
    }
  }

  void _applyManifest(String meta, int timestamp) {
    // Format: #NEBULA_MANIFEST|Name|ID|ParentID|Size|MsgID|Type|Mime|ModifiedAt
    try {
      final parts = meta.split('|');
      if (parts.length < 9) return;
      
      final id = parts[2];
      
      // Last Write Wins: Check if item is already tombstoned with a newer deletion
      if (_api.isTombstoned(id, versionTimestamp: timestamp)) {
        _log('[DELTA] Ignoring UPSERT for $id: tombstone wins (LWW).');
        return;
      }

      final type = parts[6]; // 'folder' or 'file'
      if (type == 'folder') {
        _api.upsertFolder(id, parts[3].isEmpty ? null : parts[3], parts[1]);
      } else {
        _api.upsertFile(
          id,
          parts[3].isEmpty ? null : parts[3],
          parts[1],
          int.tryParse(parts[4]) ?? 0,
          int.tryParse(parts[5]) ?? 0,
          parts[7].isEmpty ? null : parts[7],
        );
      }
      
      _log('[DELTA] Applied remote UPSERT for $type: ${parts[1]} (${parts[2]})');
      // Note: notifyListeners() deferred to end of pull() to batch UI updates
    } catch (e) {
      _log('[DELTA] Failed to apply manifest: $e');
    }
  }

  Future<void> pull({
    String? focusFolderId,
    int? forcedChatId,
    bool silent = false,
    bool ignoreThreats = false,
  }) async {
    if (_isSyncing) return;
    _isSyncing = true;
    _showGlobalProgress = !silent;
    notifyListeners();

    try {
      _log('Initiating Phase 1: Discovery...');
      int lastSyncMsgId = 0;

      final chatId = forcedChatId ?? await _anchor.findNebulaChannel();
      if (chatId == null) {
        _log('[SYNC] Warning: Vault channel not found. This is normal on fresh Linux installs. Skipping pull.');
        return;
      }

      // Phase 1: Snapshot Discovery (Robust Multi-Stage)
      final snapshotMessage = await _findLatestSnapshot(chatId);
      int? snapshotMsgId;
      int? snapshotFileId;

      if (snapshotMessage != null) {
        snapshotMsgId = snapshotMessage['id'] as int;
        final snapshotTimestamp = snapshotMessage['date'] as int? ?? 0;
        final content = snapshotMessage['content'];
        if (content != null && content['@type'] == 'messageDocument') {
          snapshotFileId = content['document']?['document']?['id'] as int?;
        }

        if (snapshotFileId != null) {
          _log('Phase 1: Found Pinned Snapshot at MsgID: $snapshotMsgId. Hydrating (T=$snapshotTimestamp)...');
          lastSyncMsgId = snapshotMsgId;

          final tempNode = FileNode(
            id: 'snapshot',
            name: 'vfs_snapshot.enc',
            size: 0,
            type: FileNodeType.file,
            parentId: 'root',
            syncStatus: SyncStatus.synced,
            createdAt: DateTime.now(),
            modifiedAt: DateTime.now(),
            mimeType: 'application/octet-stream',
            manifestMsgId: snapshotMsgId,
          );

          final tempDir = await getTemporaryDirectory();
          final tempPath = p.join(tempDir.path, 'nebula_snapshot_assembled.enc');

          try {
            await DownloadOrchestrator(vmk: _masterKey).startDownload(tempNode, hiddenSavePath: tempPath);

            String finalHydrationPath = tempPath;
            File? decryptedFile;

            if (_masterKey != null) {
              _log('[SECURITY] Decrypting VMK-protected snapshot...');
              final encryptedData = await File(tempPath).readAsBytes();
              
              if (encryptedData.length > 12) {
                final iv = encryptedData.sublist(0, 12);
                final ciphertext = encryptedData.sublist(12);
                
                // Offload heavy AES-GCM decryption to a background isolate
                final decryptedData = await compute(
                  _decryptSnapshotIsolate,
                  _SnapshotDecryptParams(
                    ciphertext: ciphertext,
                    key: _masterKey!,
                    iv: iv,
                  ),
                );
                if (decryptedData != null) {
                  final decPath = p.join(tempDir.path, 'nebula_snapshot_decrypted.json');
                  decryptedFile = File(decPath);
                  await decryptedFile.writeAsBytes(decryptedData);
                  finalHydrationPath = decPath;
                } else {
                   throw Exception('VFS Decryption Failed: Invalid VMK or corruption');
                }
              }
            } else {
              throw Exception('VFS Decryption Failed: Master Key (VMK) is not initialized.');
            }

            // Offload C++ hydration and reconciliation to a worker Isolate to keep UI fluid
            final parsedCount = await Isolate.run(() {
              return NebulaApi.instance.hydrateVfsFromSnapshot(finalHydrationPath, snapshotTimestamp);
            });
            
            if (decryptedFile != null && await decryptedFile.exists()) await decryptedFile.delete();

            if (parsedCount < 0) throw Exception('Hydration failed: $parsedCount');
            _log('Phase 2: Hydrated/Reconciled $parsedCount items.');
          } finally {
            if (await File(tempPath).exists()) await File(tempPath).delete();
          }
        }
      } else {
        _log('Phase 1: No snapshot found. Historical sync from MsgID 0.');
        lastSyncMsgId = 0;
      }

      // Phase 3: Delta Walk-Forward
      _log('Phase 3: Delta Walk-Forward from MsgID: $lastSyncMsgId using Indexed Search...');
      
      final manifestMessages = await _searchChannelMessages(chatId, '#NEBULA_MANIFEST');
      final tombstoneMessages = await _searchChannelMessages(chatId, '#NEBULA_TOMBSTONE');
      
      final allDeltas = <Map<String, dynamic>>[...manifestMessages, ...tombstoneMessages]
          .where((msg) => (msg['id'] as int) > lastSyncMsgId)
          .toList();
          
      // Sort by message ID ascending so we apply them chronologically (oldest to newest)
      allDeltas.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));

      int messagesProcessed = 0;
      for (final msg in allDeltas) {
        final content = msg['content'];
        if (content == null) continue;

        final text = content['text']?['text'] as String? ?? '';
        final caption = content['caption']?['text'] as String? ?? '';
        final meta = text.isEmpty ? caption : text;

        final date = msg['date'] as int? ?? 0;

        if (meta.contains('#NEBULA_MANIFEST')) {
          _applyManifest(meta, date);
        } else if (meta.contains('#NEBULA_TOMBSTONE')) {
          _applyTombstone(meta, date);
        }
        
        messagesProcessed++;
        if (messagesProcessed % 10 == 0) notifyListeners();
      }

      // Phase 4: Lazy Ghost Purge [CORE_LAZY]
      if (focusFolderId != null) {
        final now = DateTime.now();
        final lastPurge = _lastGhostPurgeTimes[focusFolderId] ?? DateTime.fromMillisecondsSinceEpoch(0);
        
        if (now.difference(lastPurge).inHours >= 1) {
          _log('[INTEGRITY] Throttled Ghost Purge triggered for folder: $focusFolderId');
          await _performGhostPurge(focusFolderId);
          _lastGhostPurgeTimes[focusFolderId] = now;
        } else {
          _log('[INTEGRITY] Ghost Purge for $focusFolderId skipped (Throttled).');
        }
      }

    } catch (e) {
      _log('[PULL] FAILED: $e');
      // Detect VMK mismatch / decryption failures
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('decryption failed') ||
          errorStr.contains('tag verification') ||
          errorStr.contains('invalid vmk') ||
          errorStr.contains('vfs decryption')) {
        _log('[THREAT] Sync decryption failure detected.');
        if (!ignoreThreats) {
          _log('[THREAT] Forcing session invalidation.');
          _masterKey = null;
          onSyncThreat?.call(
            'Session invalidated due to sync mismatch. Please re-enter your password.',
          );
        } else {
          _log('[THREAT] Threat suppressed (Discovery/Fresh Install).');
        }
      }
      rethrow;
    } finally {
      _isSyncing = false;
      _showGlobalProgress = false;
      notifyListeners();
    }
  }

  Future<void> pushSnapshot() async {
    if (_isSyncing) {
       _log('[PUSH] Already syncing/pushing. Aborting.');
       return;
    }
    _isSyncing = true;
    notifyListeners();

    try {
      _log('[PUSH] Initiating Safe Push (Pull before Push)...');
      await pull(); // Ensure local DB is up-to-date with remote deltas

      _log('[PUSH] Generating new VFS Snapshot...');
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) throw Exception('Vault channel not found');

      // 1. Export from C++
      final jsonStr = _api.exportVfs();
      
      // 2. Encrypt and Save to temp file
      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(tempDir.path, 'vfs_snapshot.enc');
      
      if (_masterKey == null) {
        throw Exception('[SECURITY] Cannot push snapshot: Master Key (VMK) is not initialized.');
      }

      _log('[SECURITY] Encrypting VFS Snapshot with VMK...');
      final iv = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
      final jsonData = Uint8List.fromList(utf8.encode(jsonStr));
      
      final ciphertext = CryptoUtils.aesGcmEncrypt(jsonData, _masterKey!, iv);
      
      final combined = Uint8List(iv.length + ciphertext.length);
      combined.setAll(0, iv);
      combined.setAll(iv.length, ciphertext);
      
      await File(tempPath).writeAsBytes(combined);
      _log('[SECURITY] Snapshot encrypted and saved to: $tempPath');

      // 3. Upload to Telegram
      _log('[PUSH] Uploading snapshot to Telegram...');
      final (newMsgId, _) = await _telegram.sendDocument(
        chatId: chatId,
        filePath: tempPath,
        caption: '#VFS_SNAPSHOT|${DateTime.now().toIso8601String()}',
      );
      _log('[PUSH] Upload complete. New Snapshot MsgID: $newMsgId');

      // 4. Atomic Re-pinning
      _log('[PUSH] Re-pinning... (Latest first)');
      await _telegram.pinChatMessage(chatId, newMsgId);

      // Discovery: Find old snapshots
      final pinnedMessages = await _telegram.getPinnedMessages(chatId);
      for (final msg in pinnedMessages) {
        final content = msg['content'];
        if (content == null || content['@type'] != 'messageDocument') continue;

        final caption = content['caption']?['text'] as String? ?? '';
        final fileName = content['document']?['file_name'] as String? ?? '';
        final msgId = msg['id'] as int;

        if (msgId != newMsgId && (caption.contains('#VFS_SNAPSHOT') || fileName.contains('#VFS_SNAPSHOT'))) {
          _log('[PUSH] Unpinning old snapshot: $msgId');
          await _telegram.unpinChatMessage(chatId, msgId);
        }
      }

      _log('[PUSH] Successfully promoted new snapshot $newMsgId to head.');
      
      // Garbage Collection Phase [SYNC-LEVEL-UP]
      // Purge tombstones created before this snapshot message date.
      final snapshotDate = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final gcCount = _api.cleanupTombstones(snapshotDate);
      _log('[PUSH] Garbage Collection: Purged $gcCount old tombstones.');
      
      // Garbage Collection Phase [CORE-30]
      _log('[PUSH] Initiating Log Compaction...');
      await _cleanupCloudHistory(chatId, newMsgId);

      // Cleanup
      if (await File(tempPath).exists()) await File(tempPath).delete();

    } catch (e) {
      _log('[PUSH] FAILED: $e');
      rethrow;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> _cleanupCloudHistory(int chatId, int newSnapshotMsgId) async {
    try {
      _log('[CLEANUP] Scanning for redundant messages older than $newSnapshotMsgId...');
      
      final Map<int, bool> toDelete = {};
      
      // Fetch history (up to 100 messages)
      final history = await _telegram.getChatHistory(
        chatId: chatId,
        fromMessageId: newSnapshotMsgId, // TDLib uses this as the message to start FROM (offset 0)
        offset: 0,
        limit: 100,
      );

      for (final msg in history) {
        final msgId = msg['id'] as int;
        if (msgId >= newSnapshotMsgId) continue; // Safety guard

        final content = msg['content'];
        String text = '';
        
        if (content?['@type'] == 'messageText') {
          text = content?['text']?['text'] ?? '';
        } else if (content?['@type'] == 'messageDocument') {
          text = content?['caption']?['text'] ?? '';
          final fileName = content?['document']?['file_name'] ?? '';
          text += ' $fileName';
        }

        final redundantTags = ['#VFS_SNAPSHOT', '#NEBULA_MANIFEST', '#NEBULA_TOMBSTONE'];
        final isRedundant = redundantTags.any((tag) => text.contains(tag));

        if (isRedundant) {
          toDelete[msgId] = true;
        }
      }

      if (toDelete.isNotEmpty) {
        final ids = toDelete.keys.toList();
        _log('[CLEANUP] Deleting ${ids.length} redundant messages: $ids');
        await _telegram.deleteMessages(chatId: chatId, messageIds: ids);
      } else {
        _log('[CLEANUP] No redundant messages found.');
      }
    } catch (e) {
      _log('[CLEANUP] Failed: $e');
    }
  }

  Future<void> broadcastTombstone(String id) async {
    try {
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) return;

      _log('[TOMBSTONE] Broadcasting deletion for $id...');
      await _telegram.sendTextMessage(
        chatId: chatId,
        text: '#NEBULA_TOMBSTONE|[DELETED]:$id',
      );
    } catch (e) {
      _log('[TOMBSTONE] Failed to broadcast (Offline?): $e');
    }
  }

  Future<void> broadcastBulkTombstone(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) return;

      _log('[TOMBSTONE] Broadcasting bulk deletion for ${ids.length} items...');
      final idsStr = ids.map((id) => '[DELETED]:$id').join(',');
      await _telegram.sendTextMessage(
        chatId: chatId,
        text: '#NEBULA_TOMBSTONE|ids:$idsStr',
      );
    } catch (e) {
      _log('[TOMBSTONE] Failed to broadcast bulk tombstone: $e');
    }
  }

  Future<void> broadcastManifest(FileNode node) async {
    try {
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) return;

      _log('[MANIFEST] Broadcasting manifest for ${node.name} (${node.id})...');
      
      // Format: #NEBULA_MANIFEST|Name|ID|ParentID|Size|MsgID|Type|Mime|ModifiedAt
      final type = node.type == FileNodeType.folder ? 'folder' : 'file';
      final parentId = node.parentId == 'root' ? '' : node.parentId;
      final size = node.size;
      final msgId = node.manifestMsgId ?? 0;
      final mime = node.mimeType;
      final modifiedAt = node.modifiedAt.millisecondsSinceEpoch ~/ 1000;

      final meta = '#NEBULA_MANIFEST|${node.name}|${node.id}|$parentId|$size|$msgId|$type|$mime|$modifiedAt';
      
      await _telegram.sendTextMessage(
        chatId: chatId,
        text: meta,
      );
    } catch (e) {
      _log('[MANIFEST] Failed to broadcast (Offline?): $e');
    }
  }

  void scheduleAutoPush() {
    _log('[AUTO-PUSH] Change detected. Scheduling snapshot in 60s (Log Compaction Strategy)...');
    _autoPushTimer?.cancel();
    _autoPushTimer = Timer(const Duration(seconds: 60), () async {
      _log('[AUTO-PUSH] Timer fired. Executing push...');
      try {
        await pushSnapshot();
      } catch (e) {
        _log('[AUTO-PUSH] Failed: $e');
      }
    });
  }

  Future<void> _performGhostPurge(String folderId) async {
    try {
      final jsonStr = _api.listDirectory(folderId);
      final List<dynamic> itemsData = jsonDecode(jsonStr);
      
      _log('[INTEGRITY] Verifying ${itemsData.length} records in folder $folderId...');
      
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) return;

      for (final data in itemsData) {
        // Use fromSqlJson since listDirectory returns DB rows
        final item = FileNode.fromSqlJson(data);
        
        if (item.type == FileNodeType.folder) continue;
        if (item.manifestMsgId == 0 || item.manifestMsgId == null) continue;

        try {
          final msg = await _telegram.getMessage(chatId, item.manifestMsgId!);
          if (msg == null) {
            _log('[INTEGRITY] Ghost record detected: ${item.name} (${item.id}). Purging locally...');
            _api.deleteItem(item.id);
          }
        } catch (e) {
          _log('[INTEGRITY] Warning: Could not verify ${item.name}: $e');
        }
      }
      notifyListeners();
    } catch (e) {
      _log('[INTEGRITY] Ghost Purge failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _searchChannelMessages(int chatId, String query, {int limit = 100}) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    StreamSubscription? sub;
    final extra = 'sync_search_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      sub?.cancel();

      if (update['@type'] == 'messages' || update['@type'] == 'foundMessages' || update['@type'] == 'foundChatMessages') {
        final messages = (update['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (!completer.isCompleted) completer.complete(messages);
      } else {
        if (!completer.isCompleted) completer.complete([]);
      }
    });

    _telegram.send({
      '@type': 'searchChatMessages',
      'chat_id': chatId,
      'query': query,
      'limit': limit,
      '@extra': extra,
    });

    return await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub?.cancel();
        return [];
      },
    );
  }

  Future<Map<String, dynamic>?> _findLatestSnapshot(int chatId) async {
    _log('Discovery: Stage 1 (Pinned Messages)...');
    final pinned = await _telegram.getPinnedMessages(chatId);
    for (final msg in pinned) {
      if (_isSnapshotMessage(msg)) {
        _log('Discovery SUCCESS: Found Snapshot in Pinned Messages (MsgID: ${msg['id']}).');
        return msg;
      }
    }

    _log('Discovery: Stage 2 (Indexed Server Search)...');
    try {
      final searchResults = await _searchChannelMessages(chatId, '#VFS_SNAPSHOT', limit: 10);
      for (final msg in searchResults) {
        if (_isSnapshotMessage(msg)) {
          _log('Discovery SUCCESS: Found Snapshot via Indexed Search (MsgID: ${msg['id']}).');
          return msg;
        }
      }
    } catch (e) {
      _log('Discovery Search Error: $e');
    }

    _log('Discovery FAILED: No Snapshot found in index or pins.');
    return null;
  }

  bool _isSnapshotMessage(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content == null || content['@type'] != 'messageDocument') return false;

    final caption = content['caption']?['text'] as String? ?? '';
    final filename = content['document']?['file_name'] as String? ?? '';
    
    return caption.contains('#VFS_SNAPSHOT') || filename.contains('#VFS_SNAPSHOT');
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[SYNC_ENGINE] $message');
    }
  }
}

/// Parameters for the snapshot decryption isolate.
class _SnapshotDecryptParams {
  final Uint8List ciphertext;
  final Uint8List key;
  final Uint8List iv;
  _SnapshotDecryptParams({required this.ciphertext, required this.key, required this.iv});
}

/// Top-level function for compute() — runs AES-GCM decryption in a background isolate.
Uint8List? _decryptSnapshotIsolate(_SnapshotDecryptParams params) {
  return CryptoUtils.aesGcmDecrypt(params.ciphertext, params.key, params.iv);
}
