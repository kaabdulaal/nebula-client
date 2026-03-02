import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'package:nebula_client/core/models/file_manifest.dart';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/vault_anchor_service.dart';
import 'package:nebula_client/core/models/upload_progress.dart';
import 'package:nebula_client/core/services/sync_engine.dart';
import 'package:nebula_client/features/upload/upload_manager.dart';

class UploadOrchestrator {
  Uint8List? _vmk;
  String _fileName = 'Unknown';

  UploadOrchestrator({Uint8List? vmk}) : _vmk = vmk;

  void setVmk(Uint8List key) {
    _vmk = Uint8List.fromList(key);
  }
  final UploadManager _manager = UploadManager();
  final TelegramService _telegram = TelegramService();
  final VaultAnchorService _anchor = VaultAnchorService();

  final _progressController = StreamController<UploadProgress>.broadcast();
  Stream<UploadProgress> get progress => _progressController.stream;

  DateTime? _lastChunkStartTime;
  int _totalUploadedBytes = 0;

  static const int defaultChunkSize = 50 * 1024 * 1024; 
  
  Future<void> startUpload({
    required File sourceFile,
    required String parentId,
    String? mimeType,
    String? fileId,
  }) async {
    _fileName = sourceFile.path.split(Platform.pathSeparator).last;
    final fileSize = await sourceFile.length();
    final effectiveFileId = fileId ?? _generateRandomId();
    
    // [ZOMBIE-FIX] Kill Switch: Proactively block uploads for tombstoned files
    if (NebulaApi.instance.isTombstoned(effectiveFileId)) {
      _log('[KILL-SWITCH] Aborting upload for tombstoned file: $effectiveFileId ($_fileName). Purging local ghost...');
      if (await sourceFile.exists()) await sourceFile.delete();
      return; 
    }

    try {
      _log('Initializing new upload for $_fileName ($fileSize bytes)... ID: $effectiveFileId');
      
      _log('[DEBUG] Ensuring FFI is ready...');
      await _manager.ensureInitialized();

      _log('[DEBUG] Starting pre-flight access check...');
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) {
        _log('[ERROR] Vault channel NOT FOUND.');
        throw Exception('Nebula Vault channel not found. Ensure anchor is established.');
      }
      await _manager.validateVaultAccess(chatId);
      _log('[DEBUG] Pre-flight passed. Preparing Manifest...');

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

      _saveJobState(effectiveFileId, manifest);
      _log('[DEBUG] Manifest ready. Handing over to _executeJob...');

      return await _executeJob(
        sourceFile: sourceFile,
        chatId: chatId,
        manifest: manifest,
        fek: fek,
        baseIv: baseIv,
        parentId: parentId,
        mimeType: mimeType,
      );
    } catch (e, stack) {
      _log('START UPLOAD FAILED: $e');
      if (kDebugMode) {
        debugPrint('START UPLOAD CRASHED: $e');
        debugPrintStack(stackTrace: stack);
      }
      _emitProgress(effectiveFileId, fileSize, UploadStatus.failed, error: e.toString());
      rethrow;
    }
  }

  Future<void> resumeUpload({
    required String fileId,
    required File sourceFile,
    required String parentId,
    String? mimeType,
  }) async {
    final stateJson = NebulaApi.instance.getSetting('upload_job_$fileId');
    if (stateJson == null) throw Exception('No upload state found for fileId: $fileId');
    _fileName = sourceFile.path.split(Platform.pathSeparator).last;

    // [ZOMBIE-FIX] Kill Switch: Proactively block resumed uploads for tombstoned files
    if (NebulaApi.instance.isTombstoned(fileId)) {
      _log('[KILL-SWITCH] Aborting resumed upload for tombstoned file: $fileId. Purging local ghost...');
      if (await sourceFile.exists()) await sourceFile.delete();
      NebulaApi.instance.setSetting('upload_job_$fileId', ''); // Clear job state
      return;
    }

    final manifest = FileManifest.fromJson(jsonDecode(stateJson));
    final chatId = await _anchor.findNebulaChannel();
    if (chatId == null) throw Exception('Vault channel missing during resume.');

    _log('Resuming upload for ${sourceFile.path} (Chunks completed: ${manifest.chunks.length}/${manifest.totalChunks})...');

    final fek = await _decryptFEK(manifest.cryptoMeta.encryptedFek);
    final baseIv = _hexToBytes(manifest.cryptoMeta.baseIv);

    return _executeJob(
      sourceFile: sourceFile,
      chatId: chatId,
      manifest: manifest,
      fek: fek,
      baseIv: baseIv,
      parentId: parentId,
      mimeType: mimeType,
    );
  }

  Future<void> _executeJob({
    required File sourceFile,
    required int chatId,
    required FileManifest manifest,
    required Uint8List fek,
    required Uint8List baseIv,
    required String parentId,
    String? mimeType,
  }) async {
    final fileSize = await sourceFile.length();
    final totalChunks = manifest.totalChunks;
    
    _totalUploadedBytes = manifest.chunks.fold(0, (sum, c) => sum + c.size);
    _lastChunkStartTime = DateTime.now();

    try {
      _log('[DEBUG] Entering chunk loop. Total chunks: $totalChunks');
      for (int i = 0; i < totalChunks; i++) {
         if (manifest.chunks.any((c) => c.index == i)) {
           _log('Skipping chunk $i (Already anchored)');
           continue;
         }

         _log('[DEBUG] Starting Chunk $i processing...');
         await _processChunkWithRetries(
           chatId: chatId,
           sourceFile: sourceFile,
           fileId: manifest.fileId,
           chunkIndex: i,
           startOffset: i * manifest.chunkSize,
           chunkSize: i == totalChunks - 1 
               ? (fileSize == 0 ? 0 : (fileSize - (i * manifest.chunkSize))) 
               : manifest.chunkSize,
           baseIv: baseIv,
           fek: fek,
           manifest: manifest,
           totalChunksCount: totalChunks,
         );
         
         _saveJobState(manifest.fileId, manifest);
      }
    } catch (e, stack) {
      _log('UPLOAD CRASHED: $e');
      if (kDebugMode) {
        debugPrint('UPLOAD CRASHED: $e');
        debugPrintStack(stackTrace: stack);
      }
      _emitProgress(manifest.fileId, fileSize, UploadStatus.failed, error: e.toString());
      rethrow;
    }

    _log('All chunks uploaded. Finalizing manifest...');
    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    
    final manifestIv = _generateRandomBytes(12);
    if (_vmk == null) {
      throw Exception('Vault Master Key (VMK) is not set. Cannot encrypt manifest.');
    }
    final encManifestData = _encryptData(Uint8List.fromList(manifestBytes), key: _vmk!, iv: manifestIv);
    final tempDir = await getTemporaryDirectory();
    final tempManifestPath = '${tempDir.path}/manifest_${manifest.fileId}.enc';
    
    final finalBlob = Uint8List(12 + encManifestData.length);
    finalBlob.setAll(0, manifestIv);
    finalBlob.setAll(12, encManifestData);
    File(tempManifestPath).writeAsBytesSync(finalBlob);

    final (manifestMsgId, manifestFileId) = await _telegram.sendDocument(
      chatId: chatId,
      filePath: tempManifestPath,
      caption: 'NEBULA_MANIFEST|${manifest.fileId}',
    );

    _log('Manifest confirmed and anchored (MsgID: $manifestMsgId, FileID: $manifestFileId).');

    await _finalizeVfsNode(
      fileId: manifest.fileId,
      parentId: parentId,
      name: sourceFile.path.split(Platform.pathSeparator).last,
      size: fileSize,
      manifestMsgId: manifestMsgId,
      mimeType: mimeType,
    );
    
    _progressController.add(UploadProgress(
      fileId: manifest.fileId,
      name: _fileName,
      percentComplete: 100.0,
      currentSpeed: 0,
      status: UploadStatus.success,
    ));

    NebulaApi.instance.setSetting('upload_job_${manifest.fileId}', '');
    final tempFile = File(tempManifestPath);
    if (await tempFile.exists()) await tempFile.delete();
  }

  Future<void> _finalizeVfsNode({
    required String fileId,
    required String parentId,
    required String name,
    required int size,
    required int manifestMsgId,
    String? mimeType,
  }) async {
    try {
      NebulaApi.instance.upsertFile(
        fileId,
        parentId == 'root' ? null : parentId,
        name,
        size,
        manifestMsgId,
        mimeType ?? 'application/octet-stream',
      );

      _log('File persisted to Relational VFS: $name (id: $fileId)');

      SyncEngine().scheduleAutoPush();
      _log('Auto-push scheduled for: $name');
    } catch (e) {
      _log('CRITICAL: Failed to finalize VFS node for $fileId: $e');
      rethrow;
    }
  }

  Future<void> _processChunkWithRetries({
    required int chatId,
    required File sourceFile,
    required String fileId,
    required int chunkIndex,
    required int startOffset,
    required int chunkSize,
    required Uint8List baseIv,
    required Uint8List fek,
    required FileManifest manifest,
    required int totalChunksCount,
  }) async {
    final totalFileSize = await sourceFile.length();
    
    if (manifest.chunks.any((c) => c.index == chunkIndex)) {
      _log('[ORCHESTRATOR] Chunk $chunkIndex already anchored. Skipping upload.');
      return;
    }

    int retryCount = 0;
    while (retryCount < 5) {
      try {
        _log('Processing chunk $chunkIndex/$totalChunksCount (Attempt ${retryCount + 1})...');
        
        _emitProgress(fileId, totalFileSize, UploadStatus.encrypting);
        
        final chunk = await _manager.processAndEncryptChunk(
          fileId: fileId,
          sourceFile: sourceFile,
          chunkIndex: chunkIndex,
          startOffset: startOffset,
          chunkSize: chunkSize,
          baseIv: baseIv,
          fek: fek,
        );

        _emitProgress(fileId, totalFileSize, UploadStatus.uploading);

        final tempFileName = 'upload_temp_${fileId}_$chunkIndex.enc';
        final tempDir = await getTemporaryDirectory();
        final encFilePath = '${tempDir.path}/$tempFileName';
        
        _log('[ORCHESTRATOR] Dispatching chunk $chunkIndex to TDLib and waiting for confirmation...');
        final (msgId, tdlibFileId) = await _telegram.sendDocument(
          chatId: chatId,
          filePath: encFilePath,
        );

        _log('[ORCHESTRATOR] Chunk $chunkIndex confirmed (MsgID: $msgId, FileID: $tdlibFileId).');

        _totalUploadedBytes += chunkSize;
        _emitProgress(fileId, totalFileSize, UploadStatus.uploading);

        manifest.chunks.add(FileChunk(
          index: chunkIndex,
          msgId: msgId,
          size: chunk.size,
          tag: chunk.tag,
        ));

        final tempFile = File(encFilePath);
        if (await tempFile.exists()) await tempFile.delete();
        
        return; 
      } catch (e) {
        final errorMsg = e.toString();
        if (errorMsg.contains('FLOOD_WAIT_')) {
          final waitSecs = _parseFloodWait(errorMsg);
          _log('FLOOD_WAIT detected. Waiting $waitSecs seconds...');
          _emitProgress(fileId, totalFileSize, UploadStatus.waitingFloodWait);
          await Future.delayed(Duration(seconds: waitSecs + 1));
        } else {
          retryCount++;
          if (retryCount >= 5) {
            _emitProgress(fileId, totalFileSize, UploadStatus.failed, error: e.toString());
            rethrow;
          }
          final backoff = pow(2, retryCount).toInt();
          _log('Chunk $chunkIndex failed ($e). Retrying in $backoff seconds...');
          await Future.delayed(Duration(seconds: backoff));
        }
      }
    }
  }

  void _emitProgress(String fileId, int totalSize, UploadStatus status, {String? error}) {
    final now = DateTime.now();
    double speed = 0;
    
    if (_lastChunkStartTime != null) {
      final elapsed = now.difference(_lastChunkStartTime!).inMilliseconds / 1000.0;
      if (elapsed > 0) {
        speed = _totalUploadedBytes / elapsed;
      }
    }

    final percent = totalSize > 0 ? (_totalUploadedBytes / totalSize) * 100 : 0.0;

    _progressController.add(UploadProgress(
      fileId: fileId,
      name: _fileName,
      percentComplete: percent.clamp(0.0, 100.0),
      currentSpeed: speed,
      status: status,
      error: error,
    ));
  }

  Future<String> _encryptFEK(Uint8List fek) async {
    final vmk = _vmk;
    if (vmk == null) {
      throw Exception('Vault Master Key (VMK) is not set. Cannot encrypt FEK.');
    }
    final iv = _generateRandomBytes(12);
    final ciphertext = _encryptData(fek, key: vmk, iv: iv);
    return '${_bytesToHex(iv)}:${_bytesToHex(ciphertext)}';
  }

  Future<Uint8List> _decryptFEK(String encryptedFek) async {
    final vmk = _vmk;
    if (vmk == null) {
      throw Exception('Vault Master Key (VMK) is not set. Cannot decrypt FEK.');
    }
    final parts = encryptedFek.split(':');
    final iv = _hexToBytes(parts[0]);
    final ciphertext = _hexToBytes(parts[1]);
    return _decryptData(ciphertext, key: vmk, iv: iv);
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
      NebulaApi.instance.setSetting('upload_job_$fileId', jsonEncode(manifest.toJson()));
    }
  }

  int _parseFloodWait(String message) {
    final match = RegExp(r'FLOOD_WAIT_(\d+)').firstMatch(message);
    if (match != null) {
      return int.parse(match.group(1)!);
    }
    return 30; 
  }

  String _generateRandomId() {
    return _bytesToHex(_generateRandomBytes(16));
  }

  Uint8List _generateRandomBytes(int len) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(len, (_) => random.nextInt(256)));
  }

  Uint8List _hexToBytes(String hexString) {
    final result = Uint8List(hexString.length ~/ 2);
    for (int i = 0; i < hexString.length; i += 2) {
      result[i ~/ 2] = int.parse(hexString.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[ORCHESTRATOR] $message');
    }
  }
}
