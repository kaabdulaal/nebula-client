import 'dart:async';
import 'dart:convert';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/event_bus.dart';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../api/nebula_api.dart';
import '../models/file_node.dart';
import '../../features/transfers/download_orchestrator.dart';

import 'vault_anchor_service.dart';
import '../utils/crypto_utils.dart';
import '../security/security_manager.dart';
import 'thumbnail_service.dart';

class SyncEngine extends ChangeNotifier {
  static final SyncEngine _instance = SyncEngine._internal();
  factory SyncEngine() => _instance;

  final TelegramService _telegram;
  final VaultAnchorService _anchor;
  final NebulaApi _api;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  bool _showGlobalProgress = false;
  bool get showGlobalProgress => _showGlobalProgress;

  int? _myUserId;
  StreamSubscription? _updateSub;
  final Map<String, DateTime> _lastGhostPurgeTimes = {};

  final List<String> _ghostQueue = [];
  Timer? _ghostTimer;

  int? _lastSeenSnapshotMsgId;
  
  Timer? _autoPushTimer;

  void Function(String reason)? onSyncThreat;

  SyncEngine._internal({
    TelegramService? telegramService,
    VaultAnchorService? vaultAnchorService,
    NebulaApi? nebulaApi,
  })  : _telegram = telegramService ?? TelegramService(),
        _anchor = vaultAnchorService ?? VaultAnchorService(),
        _api = nebulaApi ?? NebulaApi.instance {
    
    EventBus().on<CloudGhostDetectedEvent>().listen((event) {
      _log('[GHOST] Terminal 404 detected for ${event.nodeId}. Scheduling local purge + tombstone.');
      _api.deleteItem(event.nodeId);
      notifyListeners();
      _enqueueGhostTombstone(event.nodeId);
    });
  }

  @visibleForTesting
  SyncEngine.withMocks({
    required TelegramService telegramService,
    required VaultAnchorService vaultAnchorService,
    required NebulaApi nebulaApi,
  })  : _telegram = telegramService,
        _anchor = vaultAnchorService,
        _api = nebulaApi {
    EventBus().on<CloudGhostDetectedEvent>().listen((event) {
      _api.deleteItem(event.nodeId);
      notifyListeners();
      _enqueueGhostTombstone(event.nodeId);
    });
  }


  void _enqueueGhostTombstone(String nodeId) {
    if (_ghostQueue.contains(nodeId)) return; 
    _ghostQueue.add(nodeId);
    _log('[GHOST-QUEUE] Enqueued tombstone for $nodeId (queue size: ${_ghostQueue.length})');
    _ghostTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _processGhostQueue());
  }

  Future<void> _processGhostQueue() async {
    if (_ghostQueue.isEmpty) {
      _ghostTimer?.cancel();
      _ghostTimer = null;
      return;
    }
    final nodeId = _ghostQueue.removeAt(0);
    _log('[GHOST-QUEUE] Processing tombstone for $nodeId (${_ghostQueue.length} remaining)...');
    await broadcastTombstone(nodeId);
  }

  void pause() {
    _log('[SYNC] Engine PAUSED (Focus on Upload Priority)');
    _isPaused = true;
    _autoPushTimer?.cancel();
  }

  void resume() {
    _log('[SYNC] Engine RESUMED');
    _isPaused = false;
  }

  void reset() {
    pause();
    _lastGhostPurgeTimes.clear();
    _ghostQueue.clear();
    _ghostTimer?.cancel();
    _ghostTimer = null;
    _lastSeenSnapshotMsgId = null;
    _updateSub?.cancel();
    _updateSub = null;
    _log('[SYNC] RAM caches and timers completely cleared (Reset).');
  }

  void setMasterKey(Uint8List key) {
  }

  bool get isSecurityHardened => SecurityManager().isReady;

  Uint8List? get masterKeySnapshot => SecurityManager().vmk;

  Future<void> initializeRealTimeListener() async {
    if (_updateSub != null) return;
    
    _log('[SYNC] Initializing Real-time Sync Listener...');
    
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

        final sendingState = message['sending_state'];
        if (sendingState != null) {
          _log('[SYNC] Ignoring pending message (TempID: ${message['id']}, state: ${sendingState['@type']})');
          return;
        }

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
           _applyManifest(meta, date, msgId: message['id']);
        }
      }
    });

    _log('[SYNC] Real-time Listener active for channel $chatId');
  }

  void _applyTombstone(String meta, int timestamp) {
    try {
      String workingMeta = meta;
      final initialParts = meta.split('|');
      
      if (initialParts.length == 2 && initialParts[0] == '#NEBULA_TOMBSTONE') {
        try {
          final blob = base64Decode(initialParts[1]);
          if (blob.length >= 12) {
            final iv = blob.sublist(0, 12);
            final ciphertext = blob.sublist(12);
            final vmk = SecurityManager().vmk;
            if (vmk != null) {
              final decrypted = CryptoUtils.aesGcmDecrypt(ciphertext, vmk, iv);
              if (decrypted != null) {
                workingMeta = '#NEBULA_TOMBSTONE|${utf8.decode(decrypted)}';
                _log('[SYNC] Successfully decrypted private tombstone metadata.');
              }
            }
          }
        } catch (e) {
          _log('[SYNC] Tombstone decrypt failed (might be legacy cleartext): $e');
        }
      }

      final parts = workingMeta.split('|');
      if (parts.length < 2) return;

      final effectiveTs = timestamp > 0 ? timestamp : (DateTime.now().millisecondsSinceEpoch ~/ 1000);

      final payload = parts[1];
      if (payload.startsWith('ids:')) {
        final idsStr = payload.substring(4);
        final ids = idsStr.split(',');
        _log('[DELTA] Applying ABSOLUTE bulk DELETE for ${ids.length} items (T=$effectiveTs)...');
        for (final id in ids) {
          final trimmedId = id.trim();
          final cleanId = trimmedId.startsWith('[DELETED]:')
              ? trimmedId.substring(10)
              : trimmedId;
          _api.deleteItem(cleanId, timestamp: effectiveTs);
          _log('[DELTA] Absolute DELETE applied: $cleanId');
        }
      } else {
        final cleanId = payload.startsWith('[DELETED]:')
            ? payload.substring(10)
            : (payload.contains(':') ? payload.split(':').last : payload);
        _api.deleteItem(cleanId, timestamp: effectiveTs);
        _log('[DELTA] Absolute DELETE applied: $cleanId (T=$effectiveTs)');
      }
    } catch (e) {
      _log('[DELTA] Failed to apply tombstone: $e');
    } finally {
      notifyListeners();
    }
  }

  void _applyManifest(String meta, int timestamp, {int? msgId}) {
    try {
      String workingMeta = meta;
      final initialParts = meta.split('|');
      
      if (initialParts.length == 2 && initialParts[0] == '#NEBULA_MANIFEST') {
        try {
          final blob = base64Decode(initialParts[1]);
          if (blob.length >= 12) {
            final iv = blob.sublist(0, 12);
            final ciphertext = blob.sublist(12);
            final vmk = SecurityManager().vmk;
            if (vmk != null) {
              final decrypted = CryptoUtils.aesGcmDecrypt(ciphertext, vmk, iv);
              if (decrypted != null) {
                workingMeta = '#NEBULA_MANIFEST|${utf8.decode(decrypted)}';
                _log('[SYNC] Successfully decrypted private manifest metadata.');
              }
            }
          }
        } catch (e) {
          _log('[SYNC] Manifest decrypt failed (might be legacy cleartext): $e');
        }
      }

      final parts = workingMeta.split('|');
      if (parts.length < 9) return;
      
      final id = parts[2];
      
      if (_api.isTombstoned(id, versionTimestamp: timestamp)) {
        _log('[DELTA] Ignoring UPSERT for $id: tombstone wins (LWW).');
        return;
      }

      final parentId = parts[3].isEmpty ? 'root' : parts[3];
      final listing = _api.listDirectory(parentId);
      final List<dynamic> jsonList = jsonDecode(listing);
      final existing = jsonList.firstWhere((item) => item['id'] == id, orElse: () => null);

      if (existing != null) {
          final localTs = existing['modified_at'] as int? ?? 0;
          if (timestamp <= localTs) {
             _log('[DELTA] Ignoring UPSERT for $id: local version is newer or equal (LWW).');
             return;
          }
      }

      int manifestMsgId = int.tryParse(parts[5]) ?? 0;
      if (manifestMsgId == 0 && msgId != null) {
        manifestMsgId = msgId;
      }

      final type = parts[6]; 
      if (type == 'folder') {
        _api.upsertFolder(id, parts[3].isEmpty ? null : parts[3], parts[1], timestamp: timestamp);
      } else {
        _api.upsertFile(
          id,
          parts[3].isEmpty ? null : parts[3],
          parts[1],
          int.tryParse(parts[4]) ?? 0,
          manifestMsgId,
          parts[7].isEmpty ? null : parts[7],
          timestamp: timestamp,
        );
      }
      
      _log('[DELTA] Applied remote UPSERT (LWW) for $type: ${parts[1]} (${parts[2]}) with MsgID $manifestMsgId (T=$timestamp)');
    } catch (e) {
      _log('[DELTA] Failed to apply manifest: $e');
    } finally {
      notifyListeners();
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
    await SecurityManager().vmkFuture;
    _log('Initiating Phase 1: Discovery...');
      int lastSyncMsgId = 0;

      final chatId = forcedChatId ?? await _anchor.findNebulaChannel();
      if (chatId == null) {
        _log('[SYNC] Warning: Vault channel not found. This is normal on fresh Linux installs. Skipping pull.');
        return;
      }

      final snapshotMessage = await _findLatestSnapshot(chatId);
      int? snapshotMsgId;
      int? snapshotFileId;

      if (snapshotMessage != null) {
        var tempSnapshotMsgId = snapshotMessage['id'] as int;
        
        final liveCheck = await _telegram.getMessage(chatId, tempSnapshotMsgId);
        if (liveCheck == null) {
          _log('Discovery LIVE VALIDATION FAILED: Snapshot MsgID $tempSnapshotMsgId no longer exists in cloud. Channel may have been wiped.');
        } else {
          snapshotMsgId = tempSnapshotMsgId;
          final snapshotTimestamp = snapshotMessage['date'] as int? ?? 0;
          final content = snapshotMessage['content'];
          if (content != null && content['@type'] == 'messageDocument') {
            snapshotFileId = content['document']?['document']?['id'] as int?;
          }

          if (snapshotFileId != null) {
            _log('Phase 1: Found Pinned Snapshot at MsgID: $snapshotMsgId. Hydrating (T=$snapshotTimestamp)...');
          lastSyncMsgId = snapshotMsgId;
          _lastSeenSnapshotMsgId = snapshotMsgId; 

          final tempNode = FileNode(
            id: 'snapshot',
            name: 'vfs_snapshot.enc',
            size: 0,
            type: FileNodeType.file,
            parentId: 'root',
            syncStatus: SyncStatus.synced,
            createdAt: DateTime.fromMillisecondsSinceEpoch(TelegramService.instance.serverTime * 1000),
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(TelegramService.instance.serverTime * 1000),
            mimeType: 'application/octet-stream',
            manifestMsgId: snapshotMsgId,
          );

          final tempDir = await getTemporaryDirectory();
          final tempPath = p.join(tempDir.path, 'nebula_snapshot_assembled.enc');

          try {
            await DownloadOrchestrator().startDownload(tempNode, hiddenSavePath: tempPath);

            String finalHydrationPath = tempPath;
            File? decryptedFile;

            if (SecurityManager().isReady) {
              _log('[SECURITY] Decrypting VMK-protected snapshot...');
              final encryptedData = await File(tempPath).readAsBytes();
              
              if (encryptedData.length > 12) {
                final iv = encryptedData.sublist(0, 12);
                final ciphertext = encryptedData.sublist(12);
                
                final decryptedData = await compute(
                  _decryptSnapshotIsolate,
                  _SnapshotDecryptParams(
                    ciphertext: ciphertext,
                    key: SecurityManager().vmk!,
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

            final (upserted, deleted, skipped, needsPush) = await _safeHydrateSnapshot(finalHydrationPath, snapshotTimestamp);
            if (decryptedFile != null && await decryptedFile.exists()) await decryptedFile.delete();

            _log('Phase 2: LWW Merge complete. Upserted=$upserted, Deleted(remote)=$deleted, Skipped(local newer)=$skipped');
            if (needsPush) {
              _log('[AUTO-HEAL] Local state is ahead of cloud. Scheduling push...');
              scheduleAutoPush();
            }
          } finally {
            if (await File(tempPath).exists()) await File(tempPath).delete();
          }
        }
      }
    }

    if (snapshotFileId == null) {
        _log('Phase 1: No snapshot found. Historical sync from MsgID 0.');
        lastSyncMsgId = 0;
      }

      _log('Phase 3: Delta Bridge (Exhaustive Walk-Backward) from head down to MsgID: $lastSyncMsgId...');
      
      final Map<int, Map<String, dynamic>> dedupedDeltas = {};
      int fromId = 0; 
      bool reachedTarget = false;
      int messagesProcessed = 0;
      int totalScanCount = 0;

      while (!reachedTarget) {
        final batch = await _telegram.getChatHistory(
          chatId: chatId,
          fromMessageId: fromId,
          limit: 100,
        );

        if (batch.isEmpty) break;
        totalScanCount += batch.length;

        for (final msg in batch) {
          final msgId = msg['id'] as int;
          if (msgId <= lastSyncMsgId) {
            reachedTarget = true;
            break;
          }

          final content = msg['content'];
          if (content == null) continue;

          final text = content['text']?['text'] as String? ?? '';
          final caption = content['caption']?['text'] as String? ?? '';
          final meta = text.isEmpty ? caption : text;

          if (meta.contains('#NEBULA_MANIFEST') || meta.contains('#NEBULA_TOMBSTONE')) {
            dedupedDeltas[msgId] = msg;
          }
        }

        if (reachedTarget || batch.length < 100) break;
        fromId = batch.last['id'] as int;
        
        _log('Phase 3: Scanned ${dedupedDeltas.length} deltas... Current MsgID: $fromId');
        notifyListeners();
      }

      if (lastSyncMsgId == 0 && totalScanCount == 0) {
        _log('[HARD RECONCILIATION] Cloud channel is completely empty. Wiping local VFS to maintain parity.');
        _api.wipeLocalVfs();
        _isSyncing = false;
        _showGlobalProgress = false;
        notifyListeners();
        return;
      }
          
      _log('Phase 4: Applying ${dedupedDeltas.length} discovered deltas (LWW)...');
      final sortedDeltas = dedupedDeltas.values.toList()
        ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));

      for (final msg in sortedDeltas) {
        final content = msg['content'];
        final text = content?['text']?['text'] as String? ?? '';
        final caption = content?['caption']?['text'] as String? ?? '';
        final meta = text.isEmpty ? caption : text;
        final date = msg['date'] as int? ?? 0;

        if (meta.contains('#NEBULA_MANIFEST')) {
          _applyManifest(meta, date, msgId: msg['id']);
        } else if (meta.contains('#NEBULA_TOMBSTONE')) {
          _applyTombstone(meta, date);
        }
        
        messagesProcessed++;
        if (messagesProcessed % 10 == 0) notifyListeners();
      }

      if (sortedDeltas.isNotEmpty) {
        _log('[SYNC] New deltas applied. Clearing global thumbnail backoff.');
        ThumbnailService().clearBackoff();
        notifyListeners();
      }

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
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('decryption failed') ||
          errorStr.contains('tag verification') ||
          errorStr.contains('invalid vmk') ||
          errorStr.contains('vfs decryption') ||
          errorStr.contains('chat not found')) {
        _log('[THREAT] Sync integrity failure detected: $e');
        if (!ignoreThreats) {
          _log('[THREAT] Forcing session invalidation.');
          SecurityManager().clearKeys();
          onSyncThreat?.call(
            'Session invalidated due to sync mismatch or missing cloud vault. Please re-enter credentials.',
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
      await pull();
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) throw Exception('Vault channel not found');

      final currentHead = await _findLatestSnapshot(chatId);
      final currentHeadMsgId = currentHead?['id'] as int?;
      if (currentHeadMsgId != null &&
          _lastSeenSnapshotMsgId != null &&
          currentHeadMsgId != _lastSeenSnapshotMsgId) {
        _log('[PUSH] CAS Fail: Remote snapshot changed (was: $_lastSeenSnapshotMsgId, now: $currentHeadMsgId). Re-pulling...');
        await pull();
        scheduleAutoPush();
        return;
      }

      _log('[PUSH] Generating new VFS Snapshot...');

      final jsonStr = _api.exportVfs();
      
      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(tempDir.path, 'vfs_snapshot.enc');
      
      if (!SecurityManager().isReady) {
        throw Exception('[SECURITY] Cannot push snapshot: Master Key (VMK) is not initialized.');
      }

      _log('[SECURITY] Encrypting VFS Snapshot with VMK...');
      final iv = Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
      final jsonData = Uint8List.fromList(utf8.encode(jsonStr));
      
      final ciphertext = CryptoUtils.aesGcmEncrypt(jsonData, SecurityManager().vmk!, iv);
      
      final combined = Uint8List(iv.length + ciphertext.length);
      combined.setAll(0, iv);
      combined.setAll(iv.length, ciphertext);
      
      await File(tempPath).writeAsBytes(combined);
      _log('[SECURITY] Snapshot encrypted and saved to: $tempPath');

      _log('[PUSH] Uploading snapshot to Telegram...');
      final (newMsgId, _) = await _telegram.sendDocument(
        chatId: chatId,
        filePath: tempPath,
        caption: '#VFS_SNAPSHOT|${DateTime.fromMillisecondsSinceEpoch(TelegramService.instance.serverTime * 1000).toIso8601String()}',
      );
      _log('[PUSH] Upload complete. New Snapshot MsgID: $newMsgId');

      _log('[PUSH] Re-pinning... (Latest first)');
      await _telegram.pinChatMessage(chatId, newMsgId);

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
      
      final snapshotDate = TelegramService.instance.serverTime;
      final gcCount = _api.cleanupTombstones(snapshotDate);
      _log('[PUSH] Garbage Collection: Purged $gcCount old tombstones.');
      
      _log('[PUSH] Initiating Log Compaction...');
      await _cleanupCloudHistory(chatId, newMsgId);

      if (await File(tempPath).exists()) await File(tempPath).delete();

    } catch (e) {
      _log('[PUSH] FAILED: $e');
      rethrow;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<(int, int, int, bool)> _safeHydrateSnapshot(String jsonPath, int snapshotTimestamp) async {
    int upserted = 0, deletedAsStale = 0, skipped = 0;
    bool needsPush = false;

    Map<String, dynamic>? _normalizeExportItem(dynamic raw, {required String inferredType}) {
      if (raw is! Map<String, dynamic>) return null;
      final id = raw['id'] as String?;
      if (id == null || id.isEmpty) return null;
      return {
        'id': id,
        'name': raw['name'] as String? ?? 'unnamed',
        'parent_id': (raw['parent_id'] as String? ?? raw['folder_id'] as String? ?? 'root'),
        'type': raw.containsKey('type') ? (raw['type'] as String) : inferredType,
        'size': raw['size'] as int? ?? 0,
        'manifest_msg_id': raw['manifest_msg_id'] as int? ?? 0,
        'mime_type': raw['mime_type'] as String? ?? 'application/octet-stream',
        'modified_at': (raw['modified_at'] as int?) ?? 0,
      };
    }

    final Map<String, FileNode> localState = {};
    try {
      final vfsJson = _api.exportVfs();
      final dynamic decoded = jsonDecode(vfsJson);
      if (decoded is Map<String, dynamic>) {
        for (final raw in (decoded['folders'] as List? ?? [])) {
          final item = _normalizeExportItem(raw, inferredType: 'folder');
          if (item == null) continue;
          try {
            final node = FileNode.fromSqlJson(item);
            localState[node.id] = node;
          } catch (_) {}
        }
        for (final raw in (decoded['files'] as List? ?? [])) {
          final item = _normalizeExportItem(raw, inferredType: 'file');
          if (item == null) continue;
          try {
            final node = FileNode.fromSqlJson(item);
            localState[node.id] = node;
          } catch (_) {}
        }
      } else if (decoded is List) {
        for (final raw in decoded) {
          final item = _normalizeExportItem(raw, inferredType: 'file');
          if (item == null) continue;
          try {
            final node = FileNode.fromSqlJson(item);
            localState[node.id] = node;
          } catch (_) {}
        }
      }
    } catch (e) {
      _log('[HYDRATE] Warning: Could not load local state: $e. Proceeding with empty baseline.');
    }

    _log('[HYDRATE] Local baseline: ${localState.length} nodes (folders + files).');

    final List<Map<String, dynamic>> remoteItems = [];
    final Set<String> remoteIds = {};
    try {
      final raw = await File(jsonPath).readAsString();
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        for (final rawFolder in (decoded['folders'] as List? ?? [])) {
          final item = _normalizeExportItem(rawFolder, inferredType: 'folder');
          if (item == null) continue;
          remoteItems.add(item);
          remoteIds.add(item['id'] as String);
        }
        for (final rawFile in (decoded['files'] as List? ?? [])) {
          final item = _normalizeExportItem(rawFile, inferredType: 'file');
          if (item == null) continue;
          remoteItems.add(item);
          remoteIds.add(item['id'] as String);
        }
      } else if (decoded is List) {
        for (final rawItem in decoded) {
          final item = _normalizeExportItem(rawItem, inferredType: 'file');
          if (item == null) continue;
          remoteItems.add(item);
          remoteIds.add(item['id'] as String);
        }
      }
    } catch (e) {
      _log('[HYDRATE] Failed to parse snapshot JSON: $e');
      return (0, 0, 0, false);
    }

    _log('[HYDRATE] Remote snapshot: ${remoteItems.length} nodes. Starting LWW merge...');

    final Map<String, Set<String>> usedNames = {};
    for (final node in localState.values) {
      usedNames.putIfAbsent(node.parentId, () => {}).add(node.name.toLowerCase());
    }

    for (final item in remoteItems) {
      final id = item['id'] as String;
      final remoteTs = item['modified_at'] as int? ?? 0;
      final local = localState[id];
      final localTs = local != null
          ? (local.modifiedAt.millisecondsSinceEpoch ~/ 1000)
          : -1;

      if (localTs >= remoteTs && local != null) {
        _log('[HYDRATE] Skip $id (local T=$localTs >= remote T=$remoteTs)');
        skipped++;
        continue;
      }

      final String type = item['type'] as String;
      final rawParentId = item['parent_id'] as String? ?? 'root';
      final parentId = rawParentId.isEmpty ? 'root' : rawParentId;
      String name = item['name'] as String;

      final siblingNames = usedNames.putIfAbsent(parentId, () => {});
      if (siblingNames.contains(name.toLowerCase()) &&
          (local == null || local.name.toLowerCase() != name.toLowerCase())) {
        int suffix = 1;
        final ext = name.contains('.') ? '.${name.split('.').last}' : '';
        final base = ext.isNotEmpty ? name.substring(0, name.lastIndexOf('.')) : name;
        String candidate;
        do {
          candidate = '$base ($suffix)$ext';
          suffix++;
        } while (siblingNames.contains(candidate.toLowerCase()));
        _log('[HYDRATE] Name collision: "$name" in $parentId → renamed to "$candidate"');
        name = candidate;
      }
      siblingNames.add(name.toLowerCase());

      if (_api.isTombstoned(id, versionTimestamp: remoteTs)) {
        _log('[HYDRATE] Snapshot resurrection BLOCKED for $id: local tombstone wins over remote T=$remoteTs');
        skipped++;
        continue;
      }

      if (type == 'folder') {
        _api.upsertFolder(id, parentId == 'root' ? null : parentId, name, timestamp: remoteTs);
        _log('[HYDRATE] Upserted FOLDER: $name ($id) in $parentId T=$remoteTs');
      } else {
        final size = item['size'] as int? ?? 0;
        final manifestMsgId = item['manifest_msg_id'] as int? ?? 0;
        final mime = item['mime_type'] as String? ?? 'application/octet-stream';
        _api.upsertFile(id, parentId == 'root' ? null : parentId, name, size, manifestMsgId, mime, timestamp: remoteTs);
        _log('[HYDRATE] Upserted FILE: $name ($id) in $parentId T=$remoteTs');
      }
      upserted++;
    }

    for (final localNode in localState.values) {
      if (remoteIds.contains(localNode.id)) continue;
      
      if (localNode.syncStatus == SyncStatus.uploading) {
        _log('[HYDRATE] Active upload protected from purge: ${localNode.name} (${localNode.id})');
        continue;
      }

      final localTs = localNode.modifiedAt.millisecondsSinceEpoch ~/ 1000;

      if (localTs > snapshotTimestamp) {
        _log('[HYDRATE] Local-only node ${localNode.name} (${localNode.id}): newer than snapshot. Keeping. Flagging auto-heal.');
        needsPush = true;
      } else {
        _log('[HYDRATE] Stale local node ${localNode.name} (${localNode.id}): absent from cloud snapshot. Removing.');
        _api.deleteItem(localNode.id, timestamp: snapshotTimestamp);
        deletedAsStale++;
      }
    }

    return (upserted, deletedAsStale, skipped, needsPush);
  }

  Future<void> _cleanupCloudHistory(int chatId, int newSnapshotMsgId) async {
    try {
      _log('[CLEANUP] Scanning for redundant messages older than $newSnapshotMsgId...');
      
      final Map<int, bool> toDelete = {};
      
      final history = await _telegram.getChatHistory(
        chatId: chatId,
        fromMessageId: newSnapshotMsgId, 
        offset: 0,
        limit: 100,
      );

      for (final msg in history) {
        final msgId = msg['id'] as int;
        if (msgId >= newSnapshotMsgId) continue; 

        final content = msg['content'];
        String text = '';
        
        if (content?['@type'] == 'messageText') {
          text = content?['text']?['text'] ?? '';
        } else if (content?['@type'] == 'messageDocument') {
          text = content?['caption']?['text'] ?? '';
          final fileName = content?['document']?['file_name'] ?? '';
          text += ' $fileName';
        }

        if (text.contains('#NEBULA_MANIFEST')) {
          _log('[CLEANUP] Strictly protecting manifest message $msgId');
          continue;
        }

        final redundantTags = ['#VFS_SNAPSHOT', '#NEBULA_TOMBSTONE'];
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
      
      final payload = '[DELETED]:$id';
      final vmk = SecurityManager().vmk;
      if (vmk == null) throw Exception('VMK not available for tombstone');

      final iv = CryptoUtils.generateRandomBytes(12);
      final ciphertext = CryptoUtils.aesGcmEncrypt(Uint8List.fromList(utf8.encode(payload)), vmk, iv);
      
      final combined = Uint8List(12 + ciphertext.length);
      combined.setAll(0, iv);
      combined.setAll(12, ciphertext);
      final base64Payload = base64Encode(combined);

      await _telegram.sendTextMessage(
        chatId: chatId,
        text: '#NEBULA_TOMBSTONE|$base64Payload',
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
      
      final payload = 'ids:${ids.map((id) => '[DELETED]:$id').join(',')}';
      final vmk = SecurityManager().vmk;
      if (vmk == null) throw Exception('VMK not available for bulk tombstone');

      final iv = CryptoUtils.generateRandomBytes(12);
      final ciphertext = CryptoUtils.aesGcmEncrypt(Uint8List.fromList(utf8.encode(payload)), vmk, iv);
      
      final combined = Uint8List(12 + ciphertext.length);
      combined.setAll(0, iv);
      combined.setAll(12, ciphertext);
      final base64Payload = base64Encode(combined);

      await _telegram.sendTextMessage(
        chatId: chatId,
        text: '#NEBULA_TOMBSTONE|$base64Payload',
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
      
      final type = node.type == FileNodeType.folder ? 'folder' : 'file';
      final parentId = node.parentId == 'root' ? '' : node.parentId;
      final size = node.size;
      final msgId = node.manifestMsgId ?? 0;
      final mime = node.mimeType;
      final modifiedAt = TelegramService.instance.serverTime;

      final meta = '${node.name}|${node.id}|$parentId|$size|$msgId|$type|$mime|$modifiedAt';
      final vmk = SecurityManager().vmk;
      if (vmk == null) throw Exception('VMK not available for broadcast');

      final iv = CryptoUtils.generateRandomBytes(12);
      final ciphertext = CryptoUtils.aesGcmEncrypt(Uint8List.fromList(utf8.encode(meta)), vmk, iv);
      
      final combined = Uint8List(12 + ciphertext.length);
      combined.setAll(0, iv);
      combined.setAll(12, ciphertext);
      final base64Meta = base64Encode(combined);

      await _telegram.sendTextMessage(
        chatId: chatId,
        text: '#NEBULA_MANIFEST|$base64Meta',
      );
    } catch (e) {
      _log('[MANIFEST] Failed to broadcast (Offline?): $e');
    }
  }

  void scheduleAutoPush() {
    bool isNewVault = false;
    try {
      final vfsJson = _api.exportVfs();
      final Map<String, dynamic> vfs = jsonDecode(vfsJson);
      isNewVault = vfs.isEmpty;
    } catch (_) {}

    if (_isPaused) {
      _log('[AUTO-PUSH] Ignored (Engine PAUSED for high-priority task)');
      return;
    }

    final delay = isNewVault ? 1 : 5;
    _log('[AUTO-PUSH] Change detected. Scheduling snapshot in ${delay}s (Log Compaction Strategy)...');
    _autoPushTimer?.cancel();
    _autoPushTimer = Timer(Duration(seconds: delay), () async {
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

class _SnapshotDecryptParams {
  final Uint8List ciphertext;
  final Uint8List key;
  final Uint8List iv;
  _SnapshotDecryptParams({required this.ciphertext, required this.key, required this.iv});
}

Uint8List? _decryptSnapshotIsolate(_SnapshotDecryptParams params) {
  return CryptoUtils.aesGcmDecrypt(params.ciphertext, params.key, params.iv);
}
