import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';
import 'package:nebula_core/nebula_core_bindings_generated.dart';

class _NebulaLogger {
  static void d(String message) {
    if (kDebugMode) {
      print('[NEBULA] $message');
    }
  }
}

Future<Directory> getNebulaDocumentsDirectory() async {
  if (Platform.isLinux) {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (e) {
      final home = Platform.environment['HOME'] ?? '.';
      final nebulaDir = Directory(p.join(home, '.local', 'share', 'nebula'));

      if (!await nebulaDir.exists()) {
        await nebulaDir.create(recursive: true);
      }

      return nebulaDir;
    }
  } else {
    return await getApplicationDocumentsDirectory();
  }
}

class NebulaError implements Exception {
  final int code;
  final String message;

  NebulaError(this.code, this.message);

  @override
  String toString() => 'NebulaError(code: $code, message: $message)';
}

class NebulaApi {
  static final NebulaApi _instance = NebulaApi._internal();

  factory NebulaApi() => _instance;

  NebulaApi._internal() {
    _dylib = _loadLibrary();
    _bindings = NebulaCoreBindings(_dylib);
  }

  static NebulaApi get instance => _instance;

  late final NebulaCoreBindings _bindings;
  late final ffi.DynamicLibrary _dylib;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  ffi.DynamicLibrary _loadLibrary() {
    const libName = 'libnebula_core';

    if (Platform.isAndroid) {
      try {
        return ffi.DynamicLibrary.open('libnebula_core.so');
      } catch (e) {
        return ffi.DynamicLibrary.open('libnebula_core.so');
      }
    } else if (Platform.isLinux) {
      try {
        return ffi.DynamicLibrary.open('$libName.so');
      } catch (e) {
        final exePath = Platform.resolvedExecutable;
        final exeDir = exePath.substring(0, exePath.lastIndexOf('/'));
        try {
          return ffi.DynamicLibrary.open('$exeDir/lib/$libName.so');
        } catch (_) {
          return ffi.DynamicLibrary.open('$exeDir/lib64/$libName.so');
        }
      }
    } else if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('nebula_core.dll');
    } else if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('$libName.dylib');
    } else if (Platform.isIOS) {
      return ffi.DynamicLibrary.process();
    }
    throw UnsupportedError(
        'Platform ${Platform.operatingSystem} not supported');
  }

  Future<void> init(String dbPath, String password) async {
    if (_isInitialized) return;

    try {
      final dir = Directory(File(dbPath).parent.path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {}

    await Future.delayed(Duration.zero);

    final dbPathPtr = dbPath.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();

    try {
      final result = _bindings.nebula_init(
        dbPathPtr.cast<ffi.Char>(),
        passwordPtr.cast<ffi.Char>(),
      );

      if (result != 0) {
        throw NebulaError(
            result, 'Failed to initialize Nebula Core (Code: $result)');
      }

      _isInitialized = true;
    } catch (e) {
      _NebulaLogger.d('FFI Exception: $e');
      rethrow;
    } finally {
      calloc.free(dbPathPtr);
      calloc.free(passwordPtr);
    }
  }

  Future<int> recoverVault(String mnemonic, String newPassword) async {
    if (_isInitialized) {
      cleanup();
    }

    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');

    final dbPathPtr = dbPath.toNativeUtf8();
    final mnemonicPtr = mnemonic.toNativeUtf8();
    final passwordPtr = newPassword.toNativeUtf8();

    try {
      final result = _bindings.nebula_recover_vault(
        dbPathPtr.cast<ffi.Char>(),
        mnemonicPtr.cast<ffi.Char>(),
        passwordPtr.cast<ffi.Char>(),
      );

      if (result != 0) {
        throw NebulaError(result, 'Failed to recover vault (Code: $result)');
      }

      _isInitialized = true;
      return result;
    } finally {
      calloc.free(dbPathPtr);
      calloc.free(mnemonicPtr);
      calloc.free(passwordPtr);
    }
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('Core not initialized. Call NebulaApi().init() first.');
    }
  }

  void cleanup() {
    if (_isInitialized) {
      _bindings.nebula_cleanup();
      _isInitialized = false;
    }
  }

  String version() {
    final versionPtr = _bindings.nebula_version();
    if (versionPtr == ffi.nullptr) {
      return 'unknown';
    }
    return versionPtr.cast<Utf8>().toDartString();
  }

  int sendTelegramCode(String phone) {
    _ensureInitialized();

    final phonePtr = phone.toNativeUtf8();
    try {
      return _bindings.telegram_send_code(phonePtr.cast<ffi.Char>());
    } finally {
      calloc.free(phonePtr);
    }
  }

  int checkTelegramCode(String code) {
    _ensureInitialized();

    final codePtr = code.toNativeUtf8();
    try {
      return _bindings.telegram_check_code(codePtr.cast<ffi.Char>());
    } finally {
      calloc.free(codePtr);
    }
  }

  String generateMnemonic() {
    const bufferSize = 256; // Enough for 12 words + spaces
    final buffer = calloc<ffi.Char>(bufferSize);

    try {
      final result = _bindings.nebula_generate_mnemonic(buffer, bufferSize);
      if (result != 0) {
        throw NebulaError(result, 'Failed to generate mnemonic');
      }
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  Future<int> unlockWithPassword(String password) async {
    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');
    final dbPathPtr = dbPath.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();

    try {
      final result = _bindings.nebula_unlock_with_password(
        dbPathPtr.cast<ffi.Char>(),
        passwordPtr.cast<ffi.Char>(),
      );

      if (result == 0) {
        _isInitialized = true;
      }
      return result;
    } finally {
      calloc.free(dbPathPtr);
      calloc.free(passwordPtr);
    }
  }

  bool validateMnemonic(String mnemonic) {
    final mnemonicPtr = mnemonic.toNativeUtf8();
    try {
      final result =
          _bindings.nebula_validate_mnemonic(mnemonicPtr.cast<ffi.Char>());
      return result == 1;
    } finally {
      calloc.free(mnemonicPtr);
    }
  }

  Future<int> setPassword(String mnemonic, String password) async {
    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');
    final dbPathPtr = dbPath.toNativeUtf8();
    final mnemonicPtr = mnemonic.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();

    try {
      final result = _bindings.nebula_set_password(
        dbPathPtr.cast<ffi.Char>(),
        mnemonicPtr.cast<ffi.Char>(),
        passwordPtr.cast<ffi.Char>(),
      );
      if (result == 0) {
        _isInitialized = true;
      }
      return result;
    } finally {
      calloc.free(dbPathPtr);
      calloc.free(mnemonicPtr);
      calloc.free(passwordPtr);
    }
  }

  List<int>? encryptChunk(List<int> input, List<int> key, List<int> iv) {
    _ensureInitialized();

    if (iv.length != 12) throw ArgumentError('IV must be exactly 12 bytes');
    if (key.length != 32) throw ArgumentError('Key must be exactly 32 bytes');

    final inputPtr = calloc<ffi.Uint8>(input.length);
    final outputPtr = calloc<ffi.Uint8>(input.length + 16);
    final ivPtr = calloc<ffi.Uint8>(iv.length);
    final keyPtr = calloc<ffi.Uint8>(key.length);

    try {
      for (int i = 0; i < input.length; i++) inputPtr[i] = input[i];
      for (int i = 0; i < iv.length; i++) ivPtr[i] = iv[i];
      for (int i = 0; i < key.length; i++) keyPtr[i] = key[i];

      final resultLen = _bindings.aes_encrypt_chunk(
        inputPtr,
        input.length,
        outputPtr,
        keyPtr,
        key.length,
        ivPtr,
      );

      if (resultLen < 0) return null;

      return List<int>.generate(resultLen, (i) => outputPtr[i]);
    } finally {
      calloc.free(inputPtr);
      calloc.free(outputPtr);
      calloc.free(ivPtr);
      calloc.free(keyPtr);
    }
  }

  List<int>? decryptChunk(List<int> input, List<int> key, List<int> iv) {
    _ensureInitialized();

    if (iv.length != 12) throw ArgumentError('IV must be exactly 12 bytes');
    if (key.length != 32) throw ArgumentError('Key must be exactly 32 bytes');
    if (input.length < 16) throw ArgumentError('Input too short');

    final inputPtr = calloc<ffi.Uint8>(input.length);
    final outputPtr = calloc<ffi.Uint8>(input.length);
    final ivPtr = calloc<ffi.Uint8>(iv.length);
    final keyPtr = calloc<ffi.Uint8>(key.length);

    try {
      for (int i = 0; i < input.length; i++) inputPtr[i] = input[i];
      for (int i = 0; i < iv.length; i++) ivPtr[i] = iv[i];
      for (int i = 0; i < key.length; i++) keyPtr[i] = key[i];

      final resultLen = _bindings.aes_decrypt_chunk(
        inputPtr,
        input.length,
        outputPtr,
        keyPtr,
        key.length,
        ivPtr,
      );

      if (resultLen < 0) return null;

      return List<int>.generate(resultLen, (i) => outputPtr[i]);
    } finally {
      calloc.free(inputPtr);
      calloc.free(outputPtr);
      calloc.free(ivPtr);
      calloc.free(keyPtr);
    }
  }

  int deriveMasterKey(
      String mnemonic, ffi.Pointer<ffi.Char> outHexBuffer, int bufferLength) {
    final mnemonicPtr = mnemonic.toNativeUtf8();
    try {
      return _bindings.nebula_derive_master_key(
        mnemonicPtr.cast<ffi.Char>(),
        outHexBuffer,
        bufferLength,
      );
    } finally {
      calloc.free(mnemonicPtr);
    }
  }
}
