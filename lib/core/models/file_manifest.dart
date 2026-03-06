import 'dart:convert';
import 'dart:typed_data';

class FileChunk {
  final int index;
  final int msgId;
  final int size;
  final String tag; 

  FileChunk({
    required this.index,
    required this.msgId,
    required this.size,
    required this.tag,
  });

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'msg_id': msgId,
      'size': size,
      'tag': tag,
    };
  }

  factory FileChunk.fromJson(Map<String, dynamic> json) {
    return FileChunk(
      index: json['index'] as int,
      msgId: json['msg_id'] as int,
      size: json['size'] as int,
      tag: json['tag'] as String,
    );
  }
}

class CryptoMeta {
  final String encryptedFek;
  
  final String baseIv;

  CryptoMeta({
    required this.encryptedFek,
    required this.baseIv,
  });

  Map<String, dynamic> toJson() {
    return {
      'encrypted_fek': encryptedFek,
      'base_iv': baseIv,
    };
  }

  factory CryptoMeta.fromJson(Map<String, dynamic> json) {
    return CryptoMeta(
      encryptedFek: json['encrypted_fek'] as String,
      baseIv: json['base_iv'] as String,
    );
  }
}

class FileManifest {
  final String fileId;
  final int chunkSize;
  final int totalChunks;
  final CryptoMeta cryptoMeta;
  final List<FileChunk> chunks;

  FileManifest({
    required this.fileId,
    required this.chunkSize,
    required this.totalChunks,
    required this.cryptoMeta,
    required this.chunks,
  });

  Map<String, dynamic> toJson() {
    return {
      'file_id': fileId,
      'chunk_size': chunkSize,
      'total_chunks': totalChunks,
      'crypto_meta': cryptoMeta.toJson(),
      'chunks': chunks.map((c) => c.toJson()).toList(),
    };
  }

  factory FileManifest.fromJson(Map<String, dynamic> json) {
    return FileManifest(
      fileId: json['file_id'] as String,
      chunkSize: json['chunk_size'] as int,
      totalChunks: json['total_chunks'] as int,
      cryptoMeta: CryptoMeta.fromJson(json['crypto_meta'] as Map<String, dynamic>),
      chunks: (json['chunks'] as List)
          .map((c) => FileChunk.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }

  Uint8List getChunkIV(int index) {
    final baseBytes = _hexToBytes(cryptoMeta.baseIv);
    if (baseBytes.length != 12) {
      throw ArgumentError('Base IV must be 12 bytes');
    }

    final result = Uint8List.fromList(baseBytes);
    final indexData = ByteData(8)..setUint64(0, index, Endian.big);
    
    int carry = 0;
    for (int i = 0; i < 8; i++) {
      int pos = 11 - i;
      int val = result[pos] + indexData.getUint8(7 - i) + carry;
      result[pos] = val & 0xFF;
      carry = val >> 8;
    }
    
    for (int i = 8; i < 12; i++) {
       int pos = 11 - i;
       int val = result[pos] + carry;
       result[pos] = val & 0xFF;
       carry = val >> 8;
    }

    return result;
  }

  Uint8List getChunkAAD(int index) {
    final idBytes = utf8.encode(fileId);
    final indexBytes = ByteData(8)..setUint64(0, index, Endian.big);
    
    final aad = Uint8List(idBytes.length + 8);
    aad.setAll(0, idBytes);
    aad.setAll(idBytes.length, indexBytes.buffer.asUint8List());
    
    return aad;
  }

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  @override
  String toString() => jsonEncode(toJson());
}
