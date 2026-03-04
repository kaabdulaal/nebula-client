import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import '../api/nebula_api.dart';
import '../models/file_node.dart';
import '../models/file_manifest.dart';
import 'telegram_service.dart';
import 'vault_anchor_service.dart';
import '../security/security_manager.dart';

class ThumbnailService {
  ThumbnailService._internal();
  static final ThumbnailService _instance = ThumbnailService._internal();
  factory ThumbnailService() => _instance;

  final TelegramService _telegram = TelegramService();
  final VaultAnchorService _anchor = VaultAnchorService();
  final NebulaApi _api = NebulaApi.instance;

  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _activeTasks = {};
  final Map<String, DateTime> _retryAfter = {};
  int _activeDecryptions = 0;
  static const int _maxSimultaneousDecryptions = 4;

  void setMasterKey(Uint8List vmk) {
  }

  void reset() {
    SecurityManager().clearKeys();
    _cache.clear();
    _activeTasks.clear();
    _retryAfter.clear();
    _activeDecryptions = 0;
    debugPrint('[ThumbnailService] Session reset. VMK wiped.');
  }

  Future<Uint8List?> getThumbnail(FileNode node) {
    if (_cache.containsKey(node.id)) return Future.value(_cache[node.id]);
    
    if (_retryAfter.containsKey(node.id)) {
      if (DateTime.now().isBefore(_retryAfter[node.id]!)) {
        return Future.value(null);
      }
      _retryAfter.remove(node.id);
    }

    if (_activeTasks.containsKey(node.id)) {
      debugPrint('[Thumbnails] Joining in-flight task for ${node.name}');
      return _activeTasks[node.id]!;
    }

    final task = _fetchAndDecryptThumbnail(node);
    _activeTasks[node.id] = task;
    
    return task.then((result) {
      if (result == null) {
        _retryAfter.putIfAbsent(node.id, () => DateTime.now().add(const Duration(seconds: 30)));
      }
      return result;
    }).whenComplete(() {
      _activeTasks.remove(node.id);
    });
  }

  Future<Uint8List?> _fetchAndDecryptThumbnail(FileNode node) async {
    if (!SecurityManager().isReady) {
      debugPrint('[Thumbnails] Waiting for VMK for file: ${node.name}...');
      try {
        await SecurityManager().vmkFuture.timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[Thumbnails] Aborting ${node.name}: VMK timeout after 10s');
        _retryAfter[node.id] = DateTime.now(); 
        return null;
      }
    }

    final vmk = SecurityManager().vmk;
    if (vmk == null) return null;
    debugPrint('[Thumbnails] VMK found for ${node.name}. Proceeding with decryption...');
    debugPrint('[Thumbnails] Requesting preview for file: ${node.name}');
    if (_cache.containsKey(node.id)) return _cache[node.id];
    if (node.type != FileNodeType.file || node.manifestMsgId == null) {
      debugPrint('[Thumbnails] Aborting ${node.name}: type=${node.type.toString().split('.').last}, manifestMsgId=${node.manifestMsgId}');
      return null;
    }
    if (!node.isImage) {
      debugPrint('[Thumbnails] Aborting ${node.name}: NOT an image extension');
      return null;
    }

    int retryCount = 0;
    while (retryCount < 2) {
      try {
        final chatId = await _anchor.findNebulaChannel();
        if (chatId == null) return null;

        debugPrint('[Thumbnails] Fetching manifest for ${node.name} (Attempt ${retryCount + 1})...');
        final manifestMsg = await _telegram.getMessage(chatId, node.manifestMsgId!);
        if (manifestMsg == null) {
          debugPrint('[Thumbnails] Manifest message not found in cloud (transient or TDLib cache miss). Showing placeholder.');
          _retryAfter[node.id] = DateTime.now().add(const Duration(seconds: 2)); 
          return null;
        }

        final content = manifestMsg['content'] as Map?;
        final manifestFileId = content?['document']?['document']?['id'] as int?;
        if (manifestFileId == null) {
          debugPrint('[Thumbnails] Manifest file ID missing (transient). Showing placeholder.');
          return null;
        }

        String encManifestPath;
        try {
          encManifestPath = await _telegram.downloadFile(manifestFileId);
        } catch (e) {
          if (retryCount == 0) {
            _log('Manifest download failed, retrying: $e');
            retryCount++;
            continue;
          }
          rethrow;
        }

        final encManifestBytes = await File(encManifestPath).readAsBytes();
        if (encManifestBytes.length < 12) {
          _log('Manifest blob too short: ${encManifestBytes.length} bytes');
          return null;
        }
        
        final mIv = encManifestBytes.sublist(0, 12);
        final mCiphertext = encManifestBytes.sublist(12);
        final mPlaintext = _api.decryptChunk(mCiphertext, vmk, mIv);
        if (mPlaintext == null) {
          _log('Failed to decrypt manifest for ${node.name}. Integrity compromised or wrong VMK.');
          return null;
        }

        final manifestJson = utf8.decode(mPlaintext);
        final manifest = FileManifest.fromJson(jsonDecode(manifestJson));

        final fekParts = manifest.cryptoMeta.encryptedFek.split(':');
        if (fekParts.length < 2) return null;
        final fekIv = _hexToBytes(fekParts[0]);
        final fekCiphertext = _hexToBytes(fekParts[1]);
        final fekPlaintext = _api.decryptChunk(fekCiphertext, vmk, fekIv);
        if (fekPlaintext == null) {
          _log('Failed to decrypt FEK for ${node.name}.');
          return null;
        }
        final fek = Uint8List.fromList(fekPlaintext);

        if (manifest.chunks.isEmpty) return null;
        final chunk0 = manifest.chunks.firstWhere((c) => c.index == 0);
        
        debugPrint('[Thumbnails] Fetching chunk 0 for ${node.name}...');
        final chunkMsg = await _telegram.getMessage(chatId, chunk0.msgId);
        if (chunkMsg == null) {
          debugPrint('[Thumbnails] Chunk 0 message not found (transient or TDLib cache miss). Showing placeholder.');
          _retryAfter[node.id] = DateTime.now().add(const Duration(seconds: 2)); 
          return null;
        }

        final chunkContent = chunkMsg['content'] as Map?;
        final chunkFileId = chunkContent?['document']?['document']?['id'] as int?;
        if (chunkFileId == null) return null;

        String encChunkPath;
        try {
          encChunkPath = await _telegram.downloadFile(chunkFileId);
        } catch (e) {
          if (retryCount == 0) {
            _log('Chunk download failed, retrying: $e');
            retryCount++;
            continue;
          }
          rethrow;
        }

        final encChunkBytes = await File(encChunkPath).readAsBytes();
        final chunkIv = manifest.getChunkIV(0);
        final chunkTag = _hexToBytes(chunk0.tag);

        final fullEncrypted = Uint8List(encChunkBytes.length + 16);
        fullEncrypted.setAll(0, encChunkBytes);
        fullEncrypted.setAll(encChunkBytes.length, chunkTag);

        while (_activeDecryptions >= _maxSimultaneousDecryptions) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        
        _activeDecryptions++;
        try {
          debugPrint('[Thumbnails] Attempting final decryption for ${node.name} chunk 0...');
          final aad = _getChunkAAD(node.id, 0);
          final decrypted = NebulaApi.instance.decryptChunk(fullEncrypted, fek, chunkIv, aad: aad);
          if (decrypted != null) {
            final result = Uint8List.fromList(decrypted);
            _cache[node.id] = result;
            _log('Successfully decrypted thumbnail for ${node.name}');
            return result;
          } else {
            _log('Decryption returned NULL for ${node.name} chunk 0 (AAD: ${base64Encode(aad)}).');
          }
        } finally {
          _activeDecryptions--;
        }
        break; 
      } catch (e, stack) {
        _log('THUMBNAIL CRASH for ${node.name}: $e \n $stack');
        retryCount++;
        if (retryCount >= 2) break;
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  Uint8List _getChunkAAD(String fileId, int index) {
    final idBytes = utf8.encode(fileId);
    final indexData = ByteData(8)..setUint64(0, index, Endian.big);
    final aad = Uint8List(idBytes.length + 8);
    aad.setAll(0, idBytes);
    aad.setAll(idBytes.length, indexData.buffer.asUint8List());
    return aad;
  }

  void _log(String msg) {
    if (kDebugMode) print('[ThumbnailService] $msg');
  }

  Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) hex = '0$hex';
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  void clearCache() {
    _cache.clear();
  }

  void clearBackoff() {
    if (_retryAfter.isNotEmpty) {
      _retryAfter.clear();
      debugPrint('[Thumbnails] Backoff globally cleared due to new Sync Engine data.');
    }
  }
}
