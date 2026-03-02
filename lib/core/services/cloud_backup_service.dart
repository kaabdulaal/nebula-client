import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../api/nebula_api.dart';
import 'telegram_service.dart';

const int _kTelegramMaxFileBytes = 1500 * 1024 * 1024; 

const int _kChunkSize = 1400 * 1024 * 1024; 

const int _kIvLength = 12;

const String _kBackupPrefix = 'nebula_backup_';

const String _kCaptionPrefix = 'NEBULA_BACKUP:';

class CloudBackupService {
  final TelegramService _telegram;

  CloudBackupService({TelegramService? telegramService})
      : _telegram = telegramService ?? TelegramService();


  Uint8List deriveCloudKey(String masterKeyHex) {
    final input = '$masterKeyHex|nebula_cloud_v1';
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return Uint8List.fromList(digest.bytes);
  }


  Uint8List encryptBlob(Uint8List plaintext, Uint8List cloudKey) {
    if (cloudKey.length != 32) {
      throw ArgumentError('Cloud key must be exactly 32 bytes');
    }

    final random = Random.secure();
    final iv = Uint8List.fromList(
        List<int>.generate(_kIvLength, (_) => random.nextInt(256)));

    final encrypted = NebulaApi.instance.encryptChunk(
      plaintext.toList(),
      cloudKey.toList(),
      iv.toList(),
    );

    if (encrypted == null) {
      throw StateError('AES-GCM encryption failed (FFI returned null)');
    }

    final result = Uint8List(_kIvLength + encrypted.length);
    result.setRange(0, _kIvLength, iv);
    result.setRange(_kIvLength, result.length, encrypted);
    return result;
  }

  Uint8List decryptBlob(Uint8List ciphertext, Uint8List cloudKey) {
    if (cloudKey.length != 32) {
      throw ArgumentError('Cloud key must be exactly 32 bytes');
    }
    if (ciphertext.length < _kIvLength + 16) {
      throw ArgumentError('Ciphertext too short to be a valid encrypted blob');
    }

    final iv = ciphertext.sublist(0, _kIvLength);
    final data = ciphertext.sublist(_kIvLength);

    final decrypted = NebulaApi.instance.decryptChunk(
      data.toList(),
      cloudKey.toList(),
      iv.toList(),
    );

    if (decrypted == null) {
      throw StateError(
          'AES-GCM decryption failed (wrong key or corrupted blob)');
    }

    return Uint8List.fromList(decrypted);
  }


  Future<int> backupVault({
    required File dbFile,
    required int channelId,
    required String masterKeyHex,
    void Function(double progress)? onProgress,
  }) async {
    _log('Starting vault backup to channel $channelId...');

    final cloudKey = deriveCloudKey(masterKeyHex);
    final dbBytes = await dbFile.readAsBytes();
    final dbSize = dbBytes.length;

    _log('DB size: ${_formatBytes(dbSize)}');

    final int chunkCount = (dbSize <= _kTelegramMaxFileBytes)
        ? 1
        : (dbSize / _kChunkSize).ceil();

    _log('Uploading $chunkCount part(s)...');

    final sysTemp = await getTemporaryDirectory();
    final tempDir = await Directory('${sysTemp.path}/nebula_backup_${DateTime.now().millisecondsSinceEpoch}').create();

    try {
      for (int i = 0; i < chunkCount; i++) {
        final start = i * _kChunkSize;
        final end = min(start + _kChunkSize, dbSize);
        final chunk = dbBytes.sublist(start, end);

        _log('Encrypting part ${i + 1}/$chunkCount '
            '(${_formatBytes(chunk.length)})...');

        final encrypted = encryptBlob(Uint8List.fromList(chunk), cloudKey);

        final partNum = (i + 1).toString().padLeft(3, '0');
        final tempFile = File(p.join(tempDir.path, '$_kBackupPrefix$partNum.enc'));
        await tempFile.writeAsBytes(encrypted);

        final caption =
            '$_kCaptionPrefix$partNum/$chunkCount';
        await _uploadDocument(channelId, tempFile, caption);

        onProgress?.call((i + 1) / chunkCount);
        _log('Part ${i + 1}/$chunkCount uploaded.');
      }
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }

    _log('Vault backup complete. $chunkCount part(s) uploaded.');
    return chunkCount;
  }

  Future<bool> restoreVault({
    required int channelId,
    required File targetFile,
    required String masterKeyHex,
    void Function(double progress)? onProgress,
  }) async {
    _log('Starting vault restore from channel $channelId...');

    final cloudKey = deriveCloudKey(masterKeyHex);

    final parts = await _fetchBackupParts(channelId);
    if (parts.isEmpty) {
      _log('No backup parts found in channel $channelId.');
      return false;
    }

    _log('Found ${parts.length} backup part(s).');

    final sysTemp = await getTemporaryDirectory();
    final tempDir = await Directory('${sysTemp.path}/nebula_restore_${DateTime.now().millisecondsSinceEpoch}').create();
    final decryptedChunks = <Uint8List>[];

    try {
      for (int i = 0; i < parts.length; i++) {
        final part = parts[i];
        final messageId = part['messageId'] as int;

        _log('Downloading part ${i + 1}/${parts.length}...');
        final encryptedFile = await _downloadDocument(
            channelId, messageId, tempDir.path);

        if (encryptedFile == null) {
          _log('ERROR: Failed to download part ${i + 1}.');
          return false;
        }

        final encryptedBytes = await encryptedFile.readAsBytes();
        _log('Decrypting part ${i + 1}...');
        final decrypted = decryptBlob(encryptedBytes, cloudKey);
        decryptedChunks.add(decrypted);

        onProgress?.call((i + 1) / parts.length);
      }

      final totalSize =
          decryptedChunks.fold<int>(0, (sum, c) => sum + c.length);
      final assembled = Uint8List(totalSize);
      int offset = 0;
      for (final chunk in decryptedChunks) {
        assembled.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }

      await targetFile.writeAsBytes(assembled);
      _log('Vault restored to ${targetFile.path} (${_formatBytes(totalSize)}).');
      return true;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }


  Future<int> _uploadDocument(
      int channelId, File file, String caption) async {
    final completer = Completer<int>();
    StreamSubscription? sub;
    const extra = 'nebula_upload_doc';

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];

      if (type == 'message') {
        final msgId = update['id'] as int?;
        if (msgId != null && !completer.isCompleted) {
          completer.complete(msgId);
          sub?.cancel();
        }
      } else if (type == 'error' && !completer.isCompleted) {
        completer.completeError(
            Exception('Document upload failed: ${update['message']}'));
        sub?.cancel();
      }
    });

    _telegram.send({
      '@type': 'sendMessage',
      '@extra': extra,
      'chat_id': channelId,
      'input_message_content': {
        '@type': 'inputMessageDocument',
        'document': {
          '@type': 'inputFileLocal',
          'path': file.path,
        },
        'caption': {
          '@type': 'formattedText',
          'text': caption,
        },
        'disable_content_type_detection': true,
      },
    });

    return completer.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () {
        sub?.cancel();
        throw TimeoutException('Document upload timed out after 10 minutes');
      },
    );
  }


  Future<List<Map<String, dynamic>>> _fetchBackupParts(int channelId) async {
    final completer = Completer<List<Map<String, dynamic>>>();
    StreamSubscription? sub;
    const extra = 'nebula_getChatHistory';
    final messages = <Map<String, dynamic>>[];

    sub = _telegram.updates.listen((update) {
      if (update['@extra'] != extra) return;
      final type = update['@type'];

      if (type == 'messages') {
        final msgs = (update['messages'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [];

        for (final msg in msgs) {
          final content = msg['content'];
          if (content?['@type'] != 'messageDocument') continue;
          final caption =
              content['caption']?['text'] as String? ?? '';
          if (!caption.startsWith(_kCaptionPrefix)) continue;

          final parts =
              caption.substring(_kCaptionPrefix.length).split('/');
          if (parts.length != 2) continue;
          final partNum = int.tryParse(parts[0]);
          final totalParts = int.tryParse(parts[1]);
          if (partNum == null || totalParts == null) continue;

          messages.add({
            'messageId': msg['id'] as int,
            'partNum': partNum,
            'totalParts': totalParts,
          });
        }

        sub?.cancel();
        messages.sort((a, b) =>
            (a['partNum'] as int).compareTo(b['partNum'] as int));
        if (!completer.isCompleted) completer.complete(messages);
      } else if (type == 'error') {
        sub?.cancel();
        if (!completer.isCompleted) completer.complete([]);
      }
    });

    _telegram.send({
      '@type': 'getChatHistory',
      '@extra': extra,
      'chat_id': channelId,
      'from_message_id': 0,
      'offset': 0,
      'limit': 100,
      'only_local': false,
    });

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub?.cancel();
        return [];
      },
    );
  }

  Future<File?> _downloadDocument(
      int channelId, int messageId, String destDir) async {
    final message = await _getMessage(channelId, messageId);
    if (message == null) return null;

    final document = message['content']?['document'];
    final fileId = document?['document']?['id'] as int?;
    if (fileId == null) return null;

    return _downloadFile(fileId, destDir);
  }

  Future<Map<String, dynamic>?> _getMessage(
      int channelId, int messageId) async {
    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;
    final extra = 'nebula_getMessage_$messageId';

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
      '@extra': extra,
      'chat_id': channelId,
      'message_id': messageId,
    });

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        sub?.cancel();
        return null;
      },
    );
  }

  Future<File?> _downloadFile(int fileId, String destDir) async {
    final completer = Completer<File?>();
    StreamSubscription? sub;
    final extra = 'nebula_downloadFile_$fileId';

    sub = _telegram.updates.listen((update) {
      if (update['@type'] == 'updateFile') {
        final file = update['file'];
        if (file?['id'] != fileId) return;
        final local = file?['local'];
        final isDownloadingCompleted =
            local?['is_downloading_completed'] as bool? ?? false;
        if (isDownloadingCompleted) {
          final path = local?['path'] as String?;
          sub?.cancel();
          if (path != null && !completer.isCompleted) {
            completer.complete(File(path));
          } else if (!completer.isCompleted) {
            completer.complete(null);
          }
        }
      } else if (update['@extra'] == extra && update['@type'] == 'error') {
        sub?.cancel();
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    _telegram.send({
      '@type': 'downloadFile',
      '@extra': extra,
      'file_id': fileId,
      'priority': 1,
      'offset': 0,
      'limit': 0, 
      'synchronous': false,
    });

    return completer.future.timeout(
      const Duration(minutes: 30), 
      onTimeout: () {
        sub?.cancel();
        return null;
      },
    );
  }


  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[CloudBackup] $message');
    }
  }
}
