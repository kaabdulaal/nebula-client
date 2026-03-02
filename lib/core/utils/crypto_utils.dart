import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:encrypt/encrypt.dart' as enc;

class PBKDF2Params {
  final String password;
  final Uint8List salt;
  final int iterations;
  final int keyLength;

  PBKDF2Params({
    required this.password,
    required this.salt,
    required this.iterations,
    this.keyLength = 32,
  });
}

class CryptoUtils {
  static Uint8List aesGcmEncrypt(Uint8List input, Uint8List key, Uint8List iv) {
    final encKey = enc.Key(key);
    final encIv = enc.IV(iv);
    final encrypter = enc.Encrypter(enc.AES(encKey, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(input, iv: encIv);
    return encrypted.bytes;
  }

  static Uint8List? aesGcmDecrypt(Uint8List input, Uint8List key, Uint8List iv) {
    try {
      final encKey = enc.Key(key);
      final encIv = enc.IV(iv);
      final encrypter = enc.Encrypter(enc.AES(encKey, mode: enc.AESMode.gcm));
      final decrypted = encrypter.decryptBytes(enc.Encrypted(input), iv: encIv);
      return Uint8List.fromList(decrypted);
    } catch (e) {
      if (kDebugMode) debugPrint('[CryptoUtils] GCM Decrypt Error: $e');
      return null;
    }
  }

  static Uint8List pbkdf2HmacSha256(PBKDF2Params params) {
    final passwordBytes = utf8.encode(params.password);
    final hmac = Hmac(sha256, passwordBytes);

    final numBlocks = (params.keyLength / 32).ceil();
    final result = Uint8List(params.keyLength);

    for (int i = 1; i <= numBlocks; i++) {
      final b = ByteData(4)..setUint32(0, i, Endian.big);
      final u1Input = Uint8List(params.salt.length + 4);
      u1Input.setAll(0, params.salt);
      u1Input.setAll(params.salt.length, b.buffer.asUint8List());
      
      var ui = Uint8List.fromList(hmac.convert(u1Input).bytes);
      var ti = Uint8List.fromList(ui);

      for (int j = 1; j < params.iterations; j++) {
        ui = Uint8List.fromList(hmac.convert(ui).bytes);
        for (int k = 0; k < 32; k++) {
          ti[k] ^= ui[k];
        }
      }

      final offset = (i - 1) * 32;
      final len = (params.keyLength - offset) < 32 ? (params.keyLength - offset) : 32;
      result.setRange(offset, offset + len, ti.sublist(0, len));
    }

    return result;
  }

  static Future<Uint8List> pbkdf2Async({
    required String password,
    required Uint8List salt,
    required int iterations,
    int keyLength = 32,
  }) async {
    return compute(
      pbkdf2HmacSha256,
      PBKDF2Params(
        password: password,
        salt: salt,
        iterations: iterations,
        keyLength: keyLength,
      ),
    );
  }

  static void secureClear(Uint8List? list) {
    if (list == null) return;
    for (int i = 0; i < list.length; i++) {
      list[i] = 0;
    }
  }

  static Uint8List mnemonicToBytes(String mnemonic) {
    return Uint8List.fromList(utf8.encode(mnemonic.trim()));
  }

  static String bytesToMnemonic(Uint8List bytes) {
    return utf8.decode(bytes).trim();
  }
}
