import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'package:nebula_client/core/models/file_manifest.dart';
import 'package:nebula_client/core/models/file_node.dart';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/vault_anchor_service.dart';
import 'package:file_picker/file_picker.dart';

class DownloadOrchestrator {
  final TelegramService _telegram = TelegramService();
  final VaultAnchorService _anchor = VaultAnchorService();
  final NebulaApi _api = NebulaApi.instance;

  final _progressController = StreamController<Map<String, double>>.broadcast();
  Stream<Map<String, double>> get progressStream => _progressController.stream;

  DownloadOrchestrator() {
    _telegram.fileProgress.listen((event) {
      final (fileId, progress) = event;
      // We need to map TDLib fileId back to our nodeId if possible, 
      // but for now we just broadcast all.
      _progressController.add({fileId.toString(): progress});
    });
  }

  Future<File> startDownload(FileNode node, {Function(double)? onProgress, String? hiddenSavePath}) async {
    if (node.manifestMsgId == null) {
      throw Exception('File has no manifest ID (Cloud ghost)');
    }
    _log('Starting download for: ${node.name} (MsgID: ${node.manifestMsgId})');
    
    final chatId = await _anchor.findNebulaChannel();
    if (chatId == null) throw Exception('Vault channel not found.');
    final manifestMsg = await _telegram.getMessage(chatId, node.manifestMsgId!);
    if (manifestMsg == null) throw Exception('Failed to fetch manifest message.');

    final content = manifestMsg['content'] as Map?;
    if (content == null || content['@type'] != 'messageDocument') {
      throw Exception('Manifest message content is not a document.');
    }

    final manifestFileId = content['document']['document']['id'] as int;
    
    final encManifestPath = await _telegram.downloadFile(manifestFileId);
    _log('Manifest.enc downloaded to: $encManifestPath');

    // BYPASS DECRYPTION FOR SYSTEM SNAPSHOT
    if (node.id == 'snapshot' || node.name == 'vfs_snapshot.enc') {
      _log('[SYSTEM] Bypassing standard decryption for VFS Snapshot.');
      final rawSnapshot = File(encManifestPath);
      if (hiddenSavePath != null) {
        final target = File(hiddenSavePath);
        if (await target.exists()) await target.delete();
        await rawSnapshot.copy(hiddenSavePath);
        _log('[SYSTEM] Raw snapshot copied to: $hiddenSavePath');
        return target;
      }
      return rawSnapshot;
    }

    final dummyVMK = Uint8List(32)..fillRange(0, 32, 0x42);
    final encManifestBytes = await File(encManifestPath).readAsBytes();
    
    


    
    
    
    
    
    final manifestJson = await _decryptManifest(encManifestBytes, dummyVMK);
    final manifest = FileManifest.fromJson(jsonDecode(manifestJson));
    _log('Manifest parsed. Total chunks: ${manifest.totalChunks}');
    
    String? outputPath;
    if (hiddenSavePath != null) {
      // Headless mode for Sync Engine
      outputPath = hiddenSavePath;
    } else {
      // Standard UI mode
      outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Decrypted File',
        fileName: node.name,
      );
      if (outputPath == null) {
        throw Exception('USER_CANCELLED');
      }
    }
    
    final outputFile = File(outputPath);
    if (await outputFile.exists()) await outputFile.delete();
    await outputFile.create(recursive: true);

    final fek = await _decryptFEK(manifest.cryptoMeta.encryptedFek);
    _log('Output file prepared: $outputPath');

    for (int i = 0; i < manifest.totalChunks; i++) {
      final chunkMeta = manifest.chunks.firstWhere((c) => c.index == i);
      _log('Downloading chunk $i (MsgID: ${chunkMeta.msgId})...');

      final chunkMsg = await _telegram.getMessage(chatId, chunkMeta.msgId);
      if (chunkMsg == null) throw Exception('Failed to fetch chunk $i message.');

      final chunkContent = chunkMsg['content'] as Map?;
      final chunkFileId = chunkContent?['document']?['document']?['id'] as int?;
      if (chunkFileId == null) throw Exception('Could not find fileId for chunk $i');

      final encChunkPath = await _telegram.downloadFile(chunkFileId);
      
      final iv = manifest.getChunkIV(i);
      final aad = manifest.getChunkAAD(i);
      final tag = _hexToBytes(chunkMeta.tag);
      _log('Chunk $i: IV=${_bytesToHex(iv)} AAD=${_bytesToHex(aad)} Tag=${chunkMeta.tag}');
      
      final tempDecryptedChunkPath = '$encChunkPath.dec';
      final res = _api.decryptFile(
        encChunkPath,
        tempDecryptedChunkPath,
        fek,
        iv,
        tag,
        aad,
      );

      if (res != 0) {
        throw Exception('Decryption failed for chunk $i (Code: $res). Integrity compromised.');
      }

      final decryptedChunk = File(tempDecryptedChunkPath);
      final sink = outputFile.openWrite(mode: FileMode.append);
      await sink.addStream(decryptedChunk.openRead());
      await sink.close();

      await decryptedChunk.delete();
      await File(encChunkPath).delete();
      _log('Chunk $i appended and cleaned up.');
    }

    _log('Download complete: $outputPath');
    return outputFile;
  }

  Future<String> _decryptManifest(Uint8List encrypted, Uint8List key) async {
    if (encrypted.length < 12) throw Exception('Manifest blob too short (missing IV).');
    
    final iv = encrypted.sublist(0, 12);
    final ciphertext = encrypted.sublist(12);
    
    final result = _api.decryptChunk(ciphertext, key, iv);
    if (result == null) throw Exception('Manifest decryption failed.');
    return utf8.decode(result);
  }

  Future<Uint8List> _decryptFEK(String encryptedFek) async {
    final parts = encryptedFek.split(':');
    final iv = _hexToBytes(parts[0]);
    final ciphertext = _hexToBytes(parts[1]);
    final dummyVMK = Uint8List(32)..fillRange(0, 32, 0x42);
    final result = _api.decryptChunk(ciphertext, dummyVMK, iv);
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

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[DOWNLOAD_ORCH] $message');
    }
  }
}
