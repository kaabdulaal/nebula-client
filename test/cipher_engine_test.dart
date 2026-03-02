import 'dart:typed_data';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nebula_client/core/security/cipher_engine.dart';
import 'package:nebula_client/core/api/nebula_api.dart';

void main() {
  setUpAll(() async {
    NebulaApi();
  });

  group('CipherEngine FFI Bridge Tests', () {
    final random = Random.secure();

    Uint8List generateRandomBytes(int length) {
      return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
    }

    test('Full Roundtrip Encryption/Decryption', () {
      final key = generateRandomBytes(32);
      final iv = generateRandomBytes(12);
      final aad = Uint8List.fromList('FileMetadata:12345'.codeUnits);
      final plaintext = Uint8List.fromList('Nebula FFI Bridge Verification Test'.codeUnits);

      final encryptor = CipherEngine();
      encryptor.init(key: key, iv: iv, encrypt: true);
      encryptor.setAAD(aad);
      
      final ciphertext1 = encryptor.update(plaintext.sublist(0, 10));
      final ciphertext2 = encryptor.update(plaintext.sublist(10));
      final tag = encryptor.encryptFinalize();
      encryptor.dispose();

      final fullCiphertext = Uint8List.fromList([...ciphertext1, ...ciphertext2]);
      expect(fullCiphertext.length, equals(plaintext.length));

      final decryptor = CipherEngine();
      decryptor.init(key: key, iv: iv, encrypt: false);
      decryptor.setAAD(aad);

      final decrypted1 = decryptor.update(fullCiphertext.sublist(0, 15));
      final decrypted2 = decryptor.update(fullCiphertext.sublist(15));
      decryptor.decryptFinalize(tag);
      decryptor.dispose();

      final fullPlaintext = String.fromCharCodes([...decrypted1, ...decrypted2]);
      expect(fullPlaintext, equals('Nebula FFI Bridge Verification Test'));
    });

    test('Integrity Rejection on Tag Mismatch', () {
      final key = generateRandomBytes(32);
      final iv = generateRandomBytes(12);
      final plaintext = Uint8List.fromList('Sensitive Data'.codeUnits);

      final encryptor = CipherEngine();
      encryptor.init(key: key, iv: iv, encrypt: true);
      final ciphertext = encryptor.update(plaintext);
      final tag = encryptor.encryptFinalize();
      encryptor.dispose();

      final tamperedTag = Uint8List.fromList(tag);
      tamperedTag[0] ^= 0xFF;

      final decryptor = CipherEngine();
      decryptor.init(key: key, iv: iv, encrypt: false);
      decryptor.update(ciphertext);
      
      expect(() => decryptor.decryptFinalize(tamperedTag), throwsA(isA<CipherException>()));
      decryptor.dispose();
    });

    test('Integrity Rejection on AAD Mismatch', () {
      final key = generateRandomBytes(32);
      final iv = generateRandomBytes(12);
      final aad = Uint8List.fromList('CorrectAAD'.codeUnits);
      final wrongAad = Uint8List.fromList('WrongAAD'.codeUnits);
      final plaintext = Uint8List.fromList('Data'.codeUnits);

      final encryptor = CipherEngine();
      encryptor.init(key: key, iv: iv, encrypt: true);
      encryptor.setAAD(aad);
      final ciphertext = encryptor.update(plaintext);
      final tag = encryptor.encryptFinalize();
      encryptor.dispose();

      final decryptor = CipherEngine();
      decryptor.init(key: key, iv: iv, encrypt: false);
      decryptor.setAAD(wrongAad);
      decryptor.update(ciphertext);
      
      expect(() => decryptor.decryptFinalize(tag), throwsA(isA<CipherException>()));
      decryptor.dispose();
    });

    test('Memory Safety: Multiple Instances and Disposal', () {
      for (int i = 0; i < 50; i++) {
        final engine = CipherEngine();
        engine.init(
          key: generateRandomBytes(32),
          iv: generateRandomBytes(12),
          encrypt: true,
        );
        engine.dispose();
      }
    });
  });
}
