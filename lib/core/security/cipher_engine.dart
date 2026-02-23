import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:nebula_core/nebula_core_bindings_generated.dart';
import '../api/nebula_api.dart';

class CipherException implements Exception {
  final String message;
  final int? code;
  CipherException(this.message, [this.code]);
  @override
  String toString() => 'CipherException: $message ${code != null ? "(Code: $code)" : ""}';
}

class CipherEngine implements ffi.Finalizable {
  static final ffi.NativeFinalizer _finalizer = ffi.NativeFinalizer(
    NebulaApi.instance.lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer)>>(
      'nebula_crypto_aes_free',
    ),
  );

  final NebulaCoreBindings _bindings;
  ffi.Pointer<NebulaAesEngine>? _enginePtr;
  bool _isInitialized = false;
  bool _isEncrypting = false;

  CipherEngine() : _bindings = NebulaApi.instance.bindings {
    _enginePtr = _bindings.nebula_crypto_aes_new();
    if (_enginePtr == null || _enginePtr == ffi.nullptr) {
      throw CipherException('Failed to allocate native AES engine');
    }
    _finalizer.attach(this, _enginePtr!.cast(), detach: this);
  }

  void init({
    required Uint8List key,
    required Uint8List iv,
    required bool encrypt,
  }) {
    if (key.length != 32) throw ArgumentError('Key must be 32 bytes');
    if (iv.length != 12) throw ArgumentError('IV must be 12 bytes');

    _isEncrypting = encrypt;

    using((Arena arena) {
      final keyPtr = arena<ffi.Uint8>(key.length);
      final ivPtr = arena<ffi.Uint8>(iv.length);
      
      keyPtr.asTypedList(key.length).setAll(0, key);
      ivPtr.asTypedList(iv.length).setAll(0, iv);

      final result = _bindings.nebula_crypto_aes_init(
        _enginePtr!,
        keyPtr,
        ivPtr,
        encrypt,
      );

      if (result != 0) {
        throw CipherException('Engine initialization failed', result);
      }
      _isInitialized = true;
    });
  }

  void setAAD(Uint8List aadData) {
    _ensureInitialized();
    if (aadData.isEmpty) return;

    using((Arena arena) {
      final aadPtr = arena<ffi.Uint8>(aadData.length);
      aadPtr.asTypedList(aadData.length).setAll(0, aadData);

      final result = _bindings.nebula_crypto_aes_set_aad(
        _enginePtr!,
        aadPtr,
        aadData.length,
      );

      if (result != 0) {
        throw CipherException('Setting AAD failed', result);
      }
    });
  }

  Uint8List update(Uint8List data) {
    _ensureInitialized();
    if (data.isEmpty) return Uint8List(0);

    return using((Arena arena) {
      final inPtr = arena<ffi.Uint8>(data.length);
      final outPtr = arena<ffi.Uint8>(data.length);
      final outLenPtr = arena<ffi.Int32>();

      inPtr.asTypedList(data.length).setAll(0, data);

      final result = _bindings.nebula_crypto_aes_update(
        _enginePtr!,
        inPtr,
        data.length,
        outPtr,
        outLenPtr,
      );

      if (result != 0) {
        throw CipherException('Update failed', result);
      }

      final outLen = outLenPtr.value;
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    });
  }

  Uint8List encryptFinalize() {
    _ensureInitialized();
    if (!_isEncrypting) throw StateError('Engine not in encryption mode');

    return using((Arena arena) {
      final tagPtr = arena<ffi.Uint8>(16);
      final result = _bindings.nebula_crypto_aes_encrypt_finalize(_enginePtr!, tagPtr);

      if (result != 0) {
        throw CipherException('Encryption finalization failed', result);
      }

      return Uint8List.fromList(tagPtr.asTypedList(16));
    });
  }

  void decryptFinalize(Uint8List expectedTag) {
    _ensureInitialized();
    if (_isEncrypting) throw StateError('Engine not in decryption mode');
    if (expectedTag.length != 16) throw ArgumentError('Tag must be 16 bytes');

    using((Arena arena) {
      final tagPtr = arena<ffi.Uint8>(16);
      tagPtr.asTypedList(16).setAll(0, expectedTag);

      final result = _bindings.nebula_crypto_aes_decrypt_finalize(_enginePtr!, tagPtr);

      if (result != 0) {
        throw CipherException('Decryption finalization failed (Integrity violation)', result);
      }
    });
  }

  void dispose() {
    if (_enginePtr != null) {
      _finalizer.detach(this);
      _bindings.nebula_crypto_aes_free(_enginePtr!);
      _enginePtr = null;
    }
  }

  void _ensureInitialized() {
    if (!_isInitialized || _enginePtr == null) {
      throw StateError('CipherEngine not initialized or already disposed');
    }
  }
}
