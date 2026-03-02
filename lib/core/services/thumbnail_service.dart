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

/// A singleton service to manage secure, memory-only thumbnails.
class ThumbnailService {
  static final ThumbnailService _instance = ThumbnailService._internal();
  factory ThumbnailService() => _instance;
  ThumbnailService._internal();

  final TelegramService _telegram = TelegramService();
  final VaultAnchorService _anchor = VaultAnchorService();
  final NebulaApi _api = NebulaApi.instance;

  final Map<String, Uint8List> _cache = {};

  /// Fetches the first encrypted chunk of an image, decrypts it in an isolate,
  /// and returns the plaintext bytes (JPEG/PNG/etc).
  Future<Uint8List?> getThumbnail(FileNode node, Uint8List vmk) async {
    if (_cache.containsKey(node.id)) return _cache[node.id];
    if (node.type != FileNodeType.file || node.manifestMsgId == null) return null;
    if (!node.mimeType.startsWith('image/')) return null;

    try {
      final chatId = await _anchor.findNebulaChannel();
      if (chatId == null) return null;

      // 1. Fetch Manifest Message
      final manifestMsg = await _telegram.getMessage(chatId, node.manifestMsgId!);
      if (manifestMsg == null) return null;

      final content = manifestMsg['content'] as Map?;
      final manifestFileId = content?['document']?['document']?['id'] as int?;
      if (manifestFileId == null) return null;

      // 2. Download and Decrypt Manifest
      final encManifestPath = await _telegram.downloadFile(manifestFileId);
      final encManifestBytes = await File(encManifestPath).readAsBytes();
      if (File(encManifestPath).existsSync()) await File(encManifestPath).delete();

      if (encManifestBytes.length < 12) return null;
      final mIv = encManifestBytes.sublist(0, 12);
      final mCiphertext = encManifestBytes.sublist(12);
      final mPlaintext = _api.decryptChunk(mCiphertext, vmk, mIv);
      if (mPlaintext == null) return null;

      final manifestJson = utf8.decode(mPlaintext);
      final manifest = FileManifest.fromJson(jsonDecode(manifestJson));

      // 3. Decrypt FEK
      final fekParts = manifest.cryptoMeta.encryptedFek.split(':');
      if (fekParts.length < 2) return null;
      final fekIv = _hexToBytes(fekParts[0]);
      final fekCiphertext = _hexToBytes(fekParts[1]);
      final fekPlaintext = _api.decryptChunk(fekCiphertext, vmk, fekIv);
      if (fekPlaintext == null) return null;
      final fek = Uint8List.fromList(fekPlaintext);

      // 4. Download First Chunk
      if (manifest.chunks.isEmpty) return null;
      final chunk0 = manifest.chunks.firstWhere((c) => c.index == 0);
      final chunkMsg = await _telegram.getMessage(chatId, chunk0.msgId);
      if (chunkMsg == null) return null;

      final chunkContent = chunkMsg['content'] as Map?;
      final chunkFileId = chunkContent?['document']?['document']?['id'] as int?;
      if (chunkFileId == null) return null;

      final encChunkPath = await _telegram.downloadFile(chunkFileId);
      final encChunkBytes = await File(encChunkPath).readAsBytes();
      if (File(encChunkPath).existsSync()) await File(encChunkPath).delete();

      // 5. Decrypt in Isolate (Zero-Disk)
      final chunkIv = manifest.getChunkIV(0);
      final chunkTag = _hexToBytes(chunk0.tag);

      // Construct the data exactly as aes_decrypt_chunk expects it: [ciphertext | tag]
      // In Nebula, the Telegram file contains JUST the ciphertext.
      final fullEncrypted = Uint8List(encChunkBytes.length + 16);
      fullEncrypted.setAll(0, encChunkBytes);
      fullEncrypted.setAll(encChunkBytes.length, chunkTag);

      final decrypted = await Isolate.run(() {
        // Inside isolate, we use the singleton instance which should be re-initialized if needed
        // but since we are just calling FFI, raw bindings are safer if instance is not accessible.
        // However, NebulaApi is already designed to be safe.
        return NebulaApi.instance.decryptChunk(fullEncrypted, fek, chunkIv);
      });

      if (decrypted != null) {
        final result = Uint8List.fromList(decrypted);
        _cache[node.id] = result;
        return result;
      }
    } catch (e) {
      debugPrint('[THUMBNAIL] Failed for ${node.name}: $e');
    }
    return null;
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
}
