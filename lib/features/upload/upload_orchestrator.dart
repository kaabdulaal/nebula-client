import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'package:nebula_client/core/models/file_manifest.dart';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/vault_anchor_service.dart';
import 'package:nebula_client/core/models/upload_progress.dart';
import 'package:nebula_client/core/services/sync_engine.dart';
import 'package:nebula_client/features/upload/upload_manager.dart';
import 'package:nebula_client/core/security/security_manager.dart';
import 'package:nebula_client/core/services/event_bus.dart';
import 'package:nebula_client/core/models/file_node.dart';
import 'package:nebula_client/core/utils/format_utils.dart';
import 'package:path/path.dart' as p;


class _EncryptArgs {
  final String sourceFilePath;
  final String outPath;
  final List<int> fek;
  final List<int> iv;
  final List<int> aad;
  final int offset;
  final int length;
  _EncryptArgs({
    required this.sourceFilePath,
    required this.outPath,
    required this.fek,
    required this.iv,
    required this.aad,
    required this.offset,
    required this.length,
  });
}

class _EncryptResult {
  final String encryptedFilePath;
  final String tagHex;
  final int plainSize;
  _EncryptResult(this.encryptedFilePath, this.tagHex, this.plainSize);
}

Future<_EncryptResult> _encryptInIsolate(_EncryptArgs args) async {
  return await Isolate.run(() {
    final outTag = Uint8List(16);
    final result = NebulaApi.instance.encryptFile(
      args.sourceFilePath,
      args.outPath,
      args.fek,
      args.iv,
      aad: args.aad,
      outTag: outTag,
      offset: args.offset,
      length: args.length,
    );
    if (result != 0) {
      throw Exception('Native encryption failed (code: $result)');
    }
    final tagHex = outTag.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return _EncryptResult(args.outPath, tagHex, args.length);
  });
}

Uint8List _deriveIV(Uint8List baseIv, int index) {
  final result = Uint8List.fromList(baseIv);
  final indexData = ByteData(8)..setUint64(0, index, Endian.big);
  int carry = 0;
  for (int i = 0; i < 12; i++) {
    int pos = 11 - i;
    int addition = i < 8 ? indexData.getUint8(7 - i) : 0;
    int val = result[pos] + addition + carry;
    result[pos] = val & 0xFF;
    carry = val >> 8;
  }
  return result;
}

Uint8List _deriveAAD(String fileId, int index) {
  final idBytes = utf8.encode(fileId);
  final indexBytes = ByteData(8)..setUint64(0, index, Endian.big);
  final aad = Uint8List(idBytes.length + 8);
  aad.setAll(0, idBytes);
  aad.setAll(idBytes.length, indexBytes.buffer.asUint8List());
  return aad;
}

class UploadOrchestrator {
  static final UploadOrchestrator _instance = UploadOrchestrator._internal();
  factory UploadOrchestrator() => _instance;
  UploadOrchestrator._internal();

  void setMasterKey(Uint8List key) {}
  void setVmk(Uint8List key) => setMasterKey(key);

  final UploadManager _manager = UploadManager();
  final TelegramService _telegram = TelegramService();
  final VaultAnchorService _anchor = VaultAnchorService();

  final _progressController = StreamController<UploadProgress>.broadcast();
  Stream<UploadProgress> get progress => _progressController.stream;

  static const int defaultChunkSize = 1932735283; 

  final Map<String, DateTime> _jobStartTimes = {};
  final Map<String, DateTime> _lastEmitTimes = {};
  final Map<String, UploadStatus> _lastStatuses = {};
  final Map<String, int> _completedBytes = {};
  final Map<String, int> _activeTDLibBytes = {};

  Future<void> startUpload({
    required File sourceFile,
    required String parentId,
    String? mimeType,
    String? fileId,
  }) async {
    String fileName = sourceFile.path.split(Platform.pathSeparator).last;
    final fileSize = await sourceFile.length();

    try {
      final jsonStr = NebulaApi.instance.listDirectory(parentId);
      final List<dynamic> children = jsonDecode(jsonStr);
      final Set<String> existingNames = {};
      for (final child in children) {
        if (child is Map<String, dynamic> && child.containsKey('name')) {
          existingNames.add((child['name'] as String).toLowerCase());
        }
      }
      if (existingNames.contains(fileName.toLowerCase())) {
        int suffix = 1;
        final ext = fileName.contains('.') ? '.${fileName.split('.').last}' : '';
        final base = ext.isNotEmpty ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;
        String candidate;
        do {
          candidate = '$base ($suffix)$ext';
          suffix++;
        } while (existingNames.contains(candidate.toLowerCase()));
        _log('Name collision. Auto-renamed "$fileName" → "$candidate"');
        fileName = candidate;
      }
    } catch (e) {
      _log('[WARNING] Dedup check failed: $e');
    }

    final effectiveFileId = fileId ?? _generateRandomId();

    if (!SecurityManager().isReady) {
      throw Exception('Vault Master Key is missing. Unlock the vault first.');
    }
    if (NebulaApi.instance.isTombstoned(effectiveFileId)) {
      _log('[KILL-SWITCH] Aborting tombstoned file: $effectiveFileId');
      if (await sourceFile.exists()) await sourceFile.delete();
      return;
    }

    try {
      _log('Starting upload: $fileName ($fileSize bytes) ID: $effectiveFileId');
      await _manager.ensureInitialized();

      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) throw Exception('Nebula Vault channel not found.');
      await _manager.validateVaultAccess(chatId);

      final fek = _generateRandomBytes(32);
      final baseIv = _generateRandomBytes(12);
      final totalChunks = (fileSize / defaultChunkSize).ceil();

      final manifest = FileManifest(
        fileId: effectiveFileId,
        chunkSize: defaultChunkSize,
        totalChunks: totalChunks,
        cryptoMeta: CryptoMeta(
          encryptedFek: await _encryptFEK(fek),
          baseIv: _bytesToHex(baseIv),
        ),
        chunks: [],
      );

      NebulaApi.instance.saveUploadJob(
        sourceFile.path,
        sourceFile.lastModifiedSync().millisecondsSinceEpoch,
        fileSize,
        effectiveFileId,
      );
      _saveJobState(effectiveFileId, manifest);

      NebulaApi.instance.upsertFile(
        effectiveFileId,
        parentId == 'root' ? null : parentId,
        fileName,
        fileSize,
        0,
        mimeType ?? 'application/octet-stream',
      );
      final tempNode = FileNode(
        id: effectiveFileId, parentId: parentId,
        type: FileNodeType.file, syncStatus: SyncStatus.uploading,
        name: fileName, size: fileSize,
        mimeType: mimeType ?? 'application/octet-stream',
        createdAt: DateTime.now(), modifiedAt: DateTime.now(),
      );
      EventBus().emit(FileUploadedEvent(tempNode, jobId: effectiveFileId));

      return await _executeJob(
        sourceFile: sourceFile, chatId: chatId, manifest: manifest,
        fek: fek, baseIv: baseIv, parentId: parentId,
        mimeType: mimeType, fileName: fileName,
      );
    } catch (e, stack) {
      _log('START UPLOAD FAILED: $e');
      if (kDebugMode) debugPrintStack(stackTrace: stack);
      _emitProgress(effectiveFileId, fileName, fileSize, UploadStatus.failed, error: e.toString());
      rethrow;
    }
  }

  Future<void> resumeUpload({
    required String fileId,
    required File sourceFile,
    required String parentId,
    String? mimeType,
  }) async {
    final fileName = sourceFile.path.split(Platform.pathSeparator).last;

    if (!SecurityManager().isReady) {
      throw Exception('Vault Master Key missing for resume.');
    }
    if (NebulaApi.instance.isTombstoned(fileId)) {
      _log('[KILL-SWITCH] Aborting resumed tombstoned file: $fileId');
      if (await sourceFile.exists()) await sourceFile.delete();
      NebulaApi.instance.deleteUploadJob(sourceFile.path);
      NebulaApi.instance.setSetting('upload_manifest_$fileId', '');
      return;
    }

    final jobStr = NebulaApi.instance.getUploadJob(sourceFile.path);
    if (jobStr == null) throw Exception('No upload job found for ${sourceFile.path}');

    final job = jsonDecode(jobStr);
    if (job['last_modified'] != sourceFile.lastModifiedSync().millisecondsSinceEpoch) {
      NebulaApi.instance.deleteUploadJob(sourceFile.path);
      NebulaApi.instance.setSetting('upload_manifest_$fileId', '');
      throw Exception('File modified since upload began. Restart required.');
    }

    final stateJson = NebulaApi.instance.getSetting('upload_manifest_$fileId');
    if (stateJson == null || stateJson.isEmpty) {
      throw Exception('Manifest state missing for fileId: $fileId');
    }

    final manifest = FileManifest.fromJson(jsonDecode(stateJson));
    final chatId = await _anchor.findNebulaChannel();
    if (chatId == null) throw Exception('Vault channel missing during resume.');

    _log('Resuming upload: ${sourceFile.path} (${manifest.chunks.length}/${manifest.totalChunks} chunks done)');

    final fek = await _decryptFEK(manifest.cryptoMeta.encryptedFek);
    final baseIv = _hexToBytes(manifest.cryptoMeta.baseIv);

    return _executeJob(
      sourceFile: sourceFile, chatId: chatId, manifest: manifest,
      fek: fek, baseIv: baseIv, parentId: parentId,
      mimeType: mimeType, fileName: fileName,
    );
  }

  Future<void> _executeJob({
    required File sourceFile,
    required int chatId,
    required FileManifest manifest,
    required Uint8List fek,
    required Uint8List baseIv,
    required String parentId,
    required String fileName,
    String? mimeType,
  }) async {
    final fileSize = await sourceFile.length();
    final totalChunks = manifest.totalChunks;

    _jobStartTimes[manifest.fileId] = DateTime.now();
    _completedBytes[manifest.fileId] = 0;
    _activeTDLibBytes[manifest.fileId] = 0;

    for (final c in manifest.chunks) {
      _completedBytes[manifest.fileId] =
          (_completedBytes[manifest.fileId] ?? 0) + c.size;
    }

    try {
      SyncEngine().pause();
      TelegramService().setHighPriorityTask(true);

      _log('Entering STRICT SEQUENTIAL pipeline. Chunks: $totalChunks');

      for (int i = 0; i < totalChunks; i++) {
        if (manifest.chunks.any((c) => c.index == i)) {
          _log('Skipping chunk $i (already confirmed)');
          continue;
        }

        final offset = i * defaultChunkSize;
        final chunkSize = (offset + defaultChunkSize) > fileSize
            ? (fileSize - offset)
            : defaultChunkSize;

        _log('[STEP 1] Encrypting chunk $i/${totalChunks - 1} ($chunkSize bytes)...');
        _emitProgress(manifest.fileId, fileName, fileSize, UploadStatus.encrypting);

        final iv = _deriveIV(baseIv, i);
        final aad = _deriveAAD(manifest.fileId, i);
        final tempDir = Directory.systemTemp;
        final encPath = p.join(tempDir.path, 'nebula_up_${manifest.fileId}_$i.enc');

        final encResult = await _encryptInIsolate(_EncryptArgs(
          sourceFilePath: sourceFile.path,
          outPath: encPath,
          fek: fek,
          iv: iv,
          aad: aad,
          offset: offset,
          length: chunkSize,
        ));

        _log('[STEP 2] Uploading chunk $i to TDLib...');
        _activeTDLibBytes[manifest.fileId] = 0;
        _emitProgress(manifest.fileId, fileName, fileSize, UploadStatus.uploading);

        int msgId;
        int retries = 0;
        while (true) {
          try {
            final (mId, _) = await _telegram.sendDocument(
              chatId: chatId,
              filePath: encResult.encryptedFilePath,
              onProgress: (p) {
                _activeTDLibBytes[manifest.fileId] = (chunkSize * p).toInt();
                _emitProgress(manifest.fileId, fileName, fileSize, UploadStatus.uploading);
              },
            );
            msgId = mId;
            break;
          } catch (e) {
            if (e.toString().contains('FLOOD_WAIT_')) {
              final s = _parseFloodWait(e.toString());
              _log('[NETWORK] Flood wait: ${s}s');
              _emitProgress(manifest.fileId, fileName, fileSize, UploadStatus.waitingFloodWait);
              await Future.delayed(Duration(seconds: s + 1));
            } else {
              retries++;
              _log('[NETWORK] Upload failed chunk $i: $e (retry $retries/5)');
              if (retries >= 5) {
                _emitProgress(manifest.fileId, fileName, fileSize, UploadStatus.failed, error: e.toString());
                rethrow;
              }
              await Future.delayed(Duration(seconds: pow(2, retries).toInt()));
            }
          }
        }

        _log('[STEP 3] Chunk $i confirmed (msgId: $msgId). Persisting state...');
        manifest.chunks.add(FileChunk(
          index: i, msgId: msgId, size: chunkSize, tag: encResult.tagHex,
        ));
        NebulaApi.instance.saveUploadCheckpoint(sourceFile.path, i, msgId);
        _saveJobState(manifest.fileId, manifest);

        final tmpFile = File(encResult.encryptedFilePath);
        if (tmpFile.existsSync()) tmpFile.deleteSync();

        _completedBytes[manifest.fileId] =
            (_completedBytes[manifest.fileId] ?? 0) + chunkSize;
        _activeTDLibBytes[manifest.fileId] = 0;

        _log('[STEP 4] Chunk $i complete. Moving to next.');
      }

      _log('All $totalChunks chunks uploaded. Finalizing manifest...');
      final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));

      final manifestIv = _generateRandomBytes(12);
      if (!SecurityManager().isReady) {
        throw Exception('VMK not set. Cannot encrypt manifest.');
      }
      final encManifestData = _encryptData(
        Uint8List.fromList(manifestBytes), key: SecurityManager().vmk!, iv: manifestIv,
      );
      final tempDir = await getTemporaryDirectory();
      final tempManifestPath = p.join(tempDir.path, 'manifest_${manifest.fileId}.enc');

      final finalBlob = Uint8List(12 + encManifestData.length);
      finalBlob.setAll(0, manifestIv);
      finalBlob.setAll(12, encManifestData);
      File(tempManifestPath).writeAsBytesSync(finalBlob);

      final manifestMeta = '$fileName|${manifest.fileId}|$parentId|$fileSize|0|file|${mimeType ?? 'application/octet-stream'}|${TelegramService.instance.serverTime}';
      final metaIv = _generateRandomBytes(12);
      final encMeta = _encryptData(
        Uint8List.fromList(utf8.encode(manifestMeta)), key: SecurityManager().vmk!, iv: metaIv,
      );
      final combinedMeta = Uint8List(12 + encMeta.length);
      combinedMeta.setAll(0, metaIv);
      combinedMeta.setAll(12, encMeta);
      final base64Meta = base64Encode(combinedMeta);

      final (manifestMsgId, _) = await _telegram.sendDocument(
        chatId: chatId,
        filePath: tempManifestPath,
        caption: '#NEBULA_MANIFEST|$base64Meta',
      );

      final node = await _finalizeVfsNode(
        fileId: manifest.fileId, parentId: parentId, name: fileName,
        size: fileSize, manifestMsgId: manifestMsgId, mimeType: mimeType,
      );
      if (node != null) {
        EventBus().emit(FileUploadedEvent(node, jobId: manifest.fileId));
      }

      _progressController.add(UploadProgress(
        fileId: manifest.fileId, name: fileName,
        percentComplete: 100.0, currentSpeed: 0,
        status: UploadStatus.success, statusLabel: 'Success',
      ));

      NebulaApi.instance.deleteUploadJob(sourceFile.path);
      NebulaApi.instance.setSetting('upload_manifest_${manifest.fileId}', '');
      _jobStartTimes.remove(manifest.fileId);
      _completedBytes.remove(manifest.fileId);
      _activeTDLibBytes.remove(manifest.fileId);
      _lastEmitTimes.remove(manifest.fileId);
      _lastStatuses.remove(manifest.fileId);

      final tempFile = File(tempManifestPath);
      if (await tempFile.exists()) await tempFile.delete();

    } catch (e, stack) {
      _log('UPLOAD CRASHED: $e');
      if (kDebugMode) debugPrintStack(stackTrace: stack);
      _emitProgress(manifest.fileId, fileName, fileSize, UploadStatus.failed, error: e.toString());
      rethrow;
    } finally {
      SyncEngine().resume();
      TelegramService().setHighPriorityTask(false);
      _log('Upload finalized for: ${manifest.fileId}');
    }
  }

  Future<FileNode?> _finalizeVfsNode({
    required String fileId, required String parentId, required String name,
    required int size, required int manifestMsgId, String? mimeType,
  }) async {
    try {
      NebulaApi.instance.upsertFile(
        fileId, parentId == 'root' ? null : parentId, name, size,
        manifestMsgId, mimeType ?? 'application/octet-stream',
      );
      SyncEngine().scheduleAutoPush();
      return FileNode(
        id: fileId, parentId: parentId,
        type: FileNodeType.file, syncStatus: SyncStatus.synced,
        name: name, size: size,
        mimeType: mimeType ?? 'application/octet-stream',
        manifestMsgId: manifestMsgId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(TelegramService.instance.serverTime * 1000),
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(TelegramService.instance.serverTime * 1000),
      );
    } catch (e) {
      _log('CRITICAL: Failed to finalize VFS node for $fileId: $e');
      return null;
    }
  }

  void _emitProgress(String fileId, String fileName, int totalSize, UploadStatus status, {String? error}) {
    final now = DateTime.now();
    final lastEmit = _lastEmitTimes[fileId];
    final isTerminal = status == UploadStatus.success || status == UploadStatus.failed;
    final isStatusChange = _lastStatuses[fileId] != status;

    if (!isTerminal && !isStatusChange && lastEmit != null && now.difference(lastEmit).inMilliseconds < 200) {
      return;
    }
    _lastStatuses[fileId] = status;
    _lastEmitTimes[fileId] = now;

    final completed = _completedBytes[fileId] ?? 0;
    final active = _activeTDLibBytes[fileId] ?? 0;
    final totalUploadedBytes = completed + active;

    double speed = 0;
    final startTime = _jobStartTimes[fileId];
    if (startTime != null) {
      final elapsed = now.difference(startTime).inSeconds;
      if (elapsed > 0) speed = totalUploadedBytes / elapsed;
    }

    final percent = totalSize > 0 ? (totalUploadedBytes / totalSize) * 100 : 0.0;

    String statusLabel = status.label;
    if (status == UploadStatus.uploading || status == UploadStatus.encrypting) {
      statusLabel = '${status.label} (${NebulaFormatUtils.formatBytes(totalUploadedBytes)} / ${NebulaFormatUtils.formatBytes(totalSize)})';
    }

    _progressController.add(UploadProgress(
      fileId: fileId, name: fileName,
      percentComplete: percent.clamp(0.0, 100.0),
      currentSpeed: speed, status: status,
      statusLabel: statusLabel, error: error,
    ));
  }

  Future<String> _encryptFEK(Uint8List fek) async {
    if (!SecurityManager().isReady) throw Exception('VMK not set.');
    final iv = _generateRandomBytes(12);
    final ciphertext = _encryptData(fek, key: SecurityManager().vmk!, iv: iv);
    return '${_bytesToHex(iv)}:${_bytesToHex(ciphertext)}';
  }

  Future<Uint8List> _decryptFEK(String encryptedFek) async {
    if (!SecurityManager().isReady) throw Exception('VMK not set.');
    final parts = encryptedFek.split(':');
    final iv = _hexToBytes(parts[0]);
    final ciphertext = _hexToBytes(parts[1]);
    return _decryptData(ciphertext, key: SecurityManager().vmk!, iv: iv);
  }

  Uint8List _encryptData(Uint8List data, {required Uint8List key, required Uint8List iv}) {
    final result = NebulaApi.instance.encryptChunk(data, key, iv);
    if (result == null) throw Exception('Metadata encryption failed.');
    return Uint8List.fromList(result);
  }

  Uint8List _decryptData(Uint8List data, {required Uint8List key, required Uint8List iv}) {
    final result = NebulaApi.instance.decryptChunk(data, key, iv);
    if (result == null) throw Exception('Metadata decryption failed.');
    return Uint8List.fromList(result);
  }

  void _saveJobState(String fileId, FileManifest manifest) {
    if (NebulaApi.instance.isInitialized) {
      NebulaApi.instance.setSetting('upload_manifest_$fileId', jsonEncode(manifest.toJson()));
    }
  }

  int _parseFloodWait(String message) {
    final match = RegExp(r'FLOOD_WAIT_(\d+)').firstMatch(message);
    return match != null ? int.parse(match.group(1)!) : 30;
  }

  String _generateRandomId() => _bytesToHex(_generateRandomBytes(16));

  Uint8List _generateRandomBytes(int len) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(len, (_) => random.nextInt(256)));
  }

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

  void _log(String message) {
    if (kDebugMode) debugPrint('[ORCHESTRATOR] $message');
  }
}
