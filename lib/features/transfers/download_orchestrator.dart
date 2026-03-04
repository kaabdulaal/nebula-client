import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'package:nebula_client/core/models/file_manifest.dart';
import 'package:nebula_client/core/models/file_node.dart';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/vault_anchor_service.dart';
import 'package:nebula_client/core/security/security_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

class DownloadOrchestrator {
  static final DownloadOrchestrator _instance = DownloadOrchestrator._internal();
  factory DownloadOrchestrator() => _instance;
  DownloadOrchestrator._internal();

  final TelegramService _telegram = TelegramService();
  final VaultAnchorService _anchor = VaultAnchorService();
  final NebulaApi _api = NebulaApi.instance;

  Uint8List? _vmk;

  void setVmk(Uint8List key) {
    _vmk = Uint8List.fromList(key);
  }

  Future<File> startDownload(FileNode node, {Function(double)? onProgress, String? hiddenSavePath}) async {
    if (node.manifestMsgId == null) {
      throw Exception('File has no manifest ID (Cloud ghost)');
    }
    _log('Starting download for: ${node.name} (MsgID: ${node.manifestMsgId})');
    
    final chatId = await _anchor.findNebulaChannel();
    if (chatId == null) throw Exception('Vault channel not found.');
    
    final manifestMsg = await _telegram.getMessage(chatId, node.manifestMsgId!);
    if (manifestMsg == null) {
      _log('[WARN] Manifest message ${node.manifestMsgId} not found in cloud. Aborting download.');
      throw Exception('File manifest not found in cloud. Try again later.');
    }

    final content = manifestMsg['content'] as Map?;
    if (content == null || content['@type'] != 'messageDocument') {
      throw Exception('Manifest message content is not a document.');
    }

    final manifestFileId = content['document']['document']['id'] as int;
    final encManifestPath = await _telegram.downloadFile(manifestFileId);
    _log('Manifest.enc downloaded to: $encManifestPath');

    if (node.id == 'snapshot' || node.name == 'vfs_snapshot.enc') {
      _log('[SYSTEM] Bypassing standard decryption for VFS Snapshot.');
      final rawSnapshot = File(encManifestPath);
      if (hiddenSavePath != null) {
        final target = File(hiddenSavePath);
        if (await target.exists()) await target.delete();
        await rawSnapshot.copy(hiddenSavePath);
        return target;
      }
      return rawSnapshot;
    }

    final vmk = _vmk ?? SecurityManager().vmk;
    if (vmk == null) {
      throw Exception('Vault Master Key (VMK) is not set. Unlock the vault first.');
    }

    final encManifestBytes = await File(encManifestPath).readAsBytes();
    final manifestJson = await _decryptManifest(encManifestBytes, vmk);
    final manifest = FileManifest.fromJson(jsonDecode(manifestJson));
    _log('Manifest parsed. Total chunks: ${manifest.totalChunks}');
    
    String outputPath;
    if (hiddenSavePath != null) {
      outputPath = hiddenSavePath;
    } else {
      outputPath = await _resolveOutputPath(node.name);
    }
    
    final outputFile = File(outputPath);
    if (await outputFile.exists()) await outputFile.delete();
    await outputFile.create(recursive: true);

    final fek = await _decryptFEK(manifest.cryptoMeta.encryptedFek, vmk);
    final totalChunks = manifest.totalChunks;
    final List<String> tempFilesToCleanup = [encManifestPath];

    try {
      Future<String>? nextChunkDownFuture;
      
      for (int i = 0; i < totalChunks; i++) {
        final chunkMeta = manifest.chunks.firstWhere((c) => c.index == i);
        _log('[PIPELINE] Processing chunk $i/$totalChunks (MsgID: ${chunkMeta.msgId})...');

        final chunkMsg = await _telegram.getMessage(chatId, chunkMeta.msgId);
        if (chunkMsg == null) throw Exception('Chunk $i message not found.');
        final fileId = chunkMsg['content']?['document']?['document']?['id'] as int?;
        if (fileId == null) throw Exception('No fileId for chunk $i');

        StreamSubscription? progressSub;
        if (onProgress != null) {
          progressSub = _telegram.fileProgress.listen((event) {
            final (fId, p) = event;
            if (fId == fileId) {
              onProgress((i / totalChunks) + (p / totalChunks));
            }
          });
        }

        String encChunkPath;
        if (i == 0) {
          encChunkPath = await _downloadChunk(chatId, manifest, i);
        } else {
          _log('[PIPELINE] Awaiting pre-fetched chunk $i...');
          encChunkPath = await nextChunkDownFuture!;
        }
        tempFilesToCleanup.add(encChunkPath);
        await progressSub?.cancel();

        if (i + 1 < totalChunks) {
          _log('[PIPELINE] Pre-fetching chunk ${i + 1}...');
          nextChunkDownFuture = _downloadChunk(chatId, manifest, i + 1);
        }

        if (onProgress != null) {
          onProgress((i / totalChunks) + 0.01); 
        }

        final iv = manifest.getChunkIV(i);
        final aad = manifest.getChunkAAD(i);
        final tag = _hexToBytes(chunkMeta.tag);
        final tempDir = await getTemporaryDirectory();
        final tempDecPath = p.join(tempDir.path, 'download_part_${manifest.fileId}_$i.dec');
        tempFilesToCleanup.add(tempDecPath);

        _log('[PIPELINE] Decrypting chunk $i (Main Thread)...');
        try {
          final res = _api.decryptFile(encChunkPath, tempDecPath, fek, iv, tag, aad);
          if (res != 0) throw Exception('Native decrypt failed: $res');

          final finalFile = File(outputPath);
          final tempDecFile = File(tempDecPath);
          final sink = await finalFile.open(mode: FileMode.append);
          final reader = await tempDecFile.open(mode: FileMode.read);

          const int bufferSize = 1024 * 1024; 
          while (true) {
            final buffer = await reader.read(bufferSize);
            if (buffer.isEmpty) break;
            await sink.writeFrom(buffer);
          }
          await reader.close();
          await sink.close();
        } catch (e) {
          _log('[ERROR] Decryption/Append failed for chunk $i: $e');
          throw Exception('Decryption Failed: Integrity Mismatch (chunk $i)');
        }

        _log('[PIPELINE] Chunk $i finalized on disk.');
        
        if (onProgress != null) onProgress((i + 1) / totalChunks);
      }
    } finally {
      _log('[CLEANUP] Aggressive Garbage Collection...');
      for (final path in tempFilesToCleanup) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    _log('Download success: $outputPath');
    if (!_isDesktop && hiddenSavePath == null) {
      await _shareFileOnMobile(outputFile, node.name);
    }
    return outputFile;
  }

  Future<String> _resolveOutputPath(String fileName) async {
    if (_isDesktop) {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Decrypted File',
        fileName: fileName,
      );
      if (path == null) throw Exception('USER_CANCELLED');
      return path;
    } else {
      final tempDir = await getTemporaryDirectory();
      return p.join(tempDir.path, fileName);
    }
  }

  Future<void> _shareFileOnMobile(File file, String fileName) async {
    try {
      await Share.shareXFiles([XFile(file.path, name: fileName)]);
    } catch (_) {}
  }

  bool get _isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  Future<String> _decryptManifest(Uint8List encrypted, Uint8List key) async {
    if (encrypted.length < 12) throw Exception('Manifest missing IV.');
    final iv = encrypted.sublist(0, 12);
    final ciphertext = encrypted.sublist(12);
    final result = _api.decryptChunk(ciphertext, key, iv);
    if (result == null) throw Exception('Manifest decryption failed.');
    return utf8.decode(result);
  }

  Future<Uint8List> _decryptFEK(String encryptedFek, Uint8List vmk) async {
    final parts = encryptedFek.split(':');
    final iv = _hexToBytes(parts[0]);
    final ciphertext = _hexToBytes(parts[1]);
    final result = _api.decryptChunk(ciphertext, vmk, iv);
    if (result == null) throw Exception('FEK decryption failed.');
    return Uint8List.fromList(result);
  }

  Uint8List _hexToBytes(String hexString) {
    final result = Uint8List(hexString.length ~/ 2);
    for (int i = 0; i < hexString.length; i += 2) {
      result[i ~/ 2] = int.parse(hexString.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  Future<String> _downloadChunk(int chatId, FileManifest manifest, int index) async {
    final meta = manifest.chunks.firstWhere((c) => c.index == index);
    final msg = await _telegram.getMessage(chatId, meta.msgId);
    if (msg == null) throw Exception('Chunk $index not found.');
    final fileId = msg['content']?['document']?['document']?['id'] as int?;
    if (fileId == null) throw Exception('No fileId for chunk $index');

    final tempDir = await getTemporaryDirectory();
    final localPath = p.join(tempDir.path, 'download_temp_${manifest.fileId}_$index.enc');
    
    if (File(localPath).existsSync()) return localPath;
    return await _telegram.downloadFile(fileId);
  }

  void _log(String message) {
    if (kDebugMode) print('[DOWNLOAD_ORCH] $message');
  }
}
