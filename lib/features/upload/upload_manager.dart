import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:nebula_core/nebula_core.dart';
import '../../core/models/file_manifest.dart';
import '../../core/services/vault_anchor_service.dart';
import '../../core/services/telegram_service.dart';

class UploadManager {
  static const int microBlockSize = 2 * 1024 * 1024; 
  static const int tagSize = 16; 

  final NebulaCore _core = NebulaCore();
  
  Future<void> ensureInitialized() async {
    _core.ffi;
  }

  Future<void> validateVaultAccess(int chatId) async {
    final anchorService = VaultAnchorService();
    final telegram = TelegramService();
    
    bool allowed = await anchorService.canUpload(chatId);
    if (allowed) return;

    print('[UploadManager] Permission denied on first check. Refreshing chat state and retrying in 2s...');
    
    await telegram.getChat(chatId);
    await Future.delayed(const Duration(seconds: 2));

    allowed = await anchorService.canUpload(chatId);
    if (!allowed) {
      throw Exception('Nebula Permission Denied: You do not have write access to Vault chat $chatId. '
          'Internal TDLib permissions might be stale.');
    }
    
    print('[UploadManager] Permission granted after retry/refresh.');
  }

  static Future<void> clearOrphanedTempFiles() async {
    final tempDir = Directory.systemTemp;
    try {
      final files = tempDir.listSync();
      for (final file in files) {
        if (file is File && file.path.contains('upload_temp_')) {
          await file.delete();
        }
      }
      print('[UploadManager] Orphaned temp files cleared.');
    } catch (e) {
      print('[UploadManager] Cleanup error: $e');
    }
  }

  Future<FileChunk> processAndEncryptChunk({
    required String fileId,
    required File sourceFile,
    required int chunkIndex,
    required int startOffset,
    required int chunkSize,
    required Uint8List baseIv,
    required Uint8List fek,
  }) async {
    final tempPath = '${Directory.systemTemp.path}/upload_temp_${fileId}_$chunkIndex.enc';
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();

    RandomAccessFile? raf;
    RandomAccessFile? sink;
    final coreFfi = _core.ffi;
    final engine = coreFfi.aesNew();

    try {
      raf = await sourceFile.open(mode: FileMode.read);
      await raf.setPosition(startOffset);
      sink = await tempFile.open(mode: FileMode.write);

      final keyPtr = _uint8ListToPointer(fek);
      try {
        final ivPtr = _uint8ListToPointer(_deriveChunkIV(baseIv, chunkIndex));
        try {
          final initRes = coreFfi.aesInit(engine, keyPtr, ivPtr, true);
          if (initRes != 0) throw Exception('CipherEngine init failed: $initRes');

          final aad = _getChunkAAD(fileId, chunkIndex);
          final aadPtr = _uint8ListToPointer(aad);
          try {
            final aadRes = coreFfi.aesSetAAD(engine, aadPtr, aad.length);
            if (aadRes != 0) throw Exception('CipherEngine setAAD failed: $aadRes');
          } finally {
            calloc.free(aadPtr);
          }

          int remaining = chunkSize;
          final inBuffer = calloc<ffi.Uint8>(microBlockSize);
          final outBuffer = calloc<ffi.Uint8>(microBlockSize + 64);
          final outLenPtr = calloc<ffi.Int32>();

          try {
            while (remaining > 0) {
              final readSize = remaining < microBlockSize ? remaining : microBlockSize;
              final bytes = await raf.read(readSize);
              if (bytes.isEmpty) break;

              for (int i = 0; i < bytes.length; i++) {
                inBuffer[i] = bytes[i];
              }

              final updateRes = coreFfi.aesUpdate(
                engine,
                inBuffer,
                bytes.length,
                outBuffer,
                outLenPtr,
              );
              if (updateRes != 0) throw Exception('CipherEngine update failed: $updateRes');

              final producedLen = outLenPtr.value;
              if (producedLen > 0) {
                await sink.writeFrom(outBuffer.cast<ffi.Uint8>().asTypedList(producedLen));
              }

              remaining -= bytes.length;
            }

            final tagBuffer = calloc<ffi.Uint8>(tagSize);
            try {
              final finalRes = coreFfi.aesEncryptFinalize(engine, tagBuffer);
              if (finalRes != 0) throw Exception('CipherEngine finalize failed: $finalRes');

              final tag = _uint8PointerToHex(tagBuffer, tagSize);

              return FileChunk(
                index: chunkIndex,
                msgId: 0, 
                size: chunkSize - remaining, 
                tag: tag,
              );
            } finally {
              calloc.free(tagBuffer);
            }
          } finally {
            calloc.free(inBuffer);
            calloc.free(outBuffer);
            calloc.free(outLenPtr);
          }
        } finally {
          calloc.free(ivPtr);
        }
      } finally {
        calloc.free(keyPtr);
      }
    } finally {
      coreFfi.aesFree(engine);
      await raf?.close();
      await sink?.close();
    }
  }

  Uint8List _deriveChunkIV(Uint8List baseIv, int index) {
    if (baseIv.length != 12) throw ArgumentError('Base IV must be 12 bytes');
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

  Uint8List _getChunkAAD(String fileId, int index) {
    final idBytes = utf8.encode(fileId);
    final indexBytes = ByteData(8)..setUint64(0, index, Endian.big);
    final aad = Uint8List(idBytes.length + 8);
    aad.setAll(0, idBytes);
    aad.setAll(idBytes.length, indexBytes.buffer.asUint8List());
    return aad;
  }

  ffi.Pointer<ffi.Uint8> _uint8ListToPointer(Uint8List list) {
    final ptr = calloc<ffi.Uint8>(list.length);
    for (int i = 0; i < list.length; i++) {
      ptr[i] = list[i];
    }
    return ptr;
  }

  String _uint8PointerToHex(ffi.Pointer<ffi.Uint8> ptr, int len) {
    return List.generate(len, (i) => ptr[i].toRadixString(16).padLeft(2, '0')).join('');
  }
}
