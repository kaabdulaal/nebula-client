import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';
import 'package:convert/convert.dart';
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
    final dir = Platform.isAndroid 
        ? await getApplicationSupportDirectory() 
        : await getApplicationDocumentsDirectory();
    return Directory(dir.path).absolute;
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
  NebulaCoreBindings get bindings => _bindings;
  late final ffi.DynamicLibrary _dylib;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  ffi.Pointer<T> lookup<T extends ffi.NativeType>(String symbolName) {
    return _dylib.lookup<T>(symbolName);
  }

  ffi.DynamicLibrary _loadLibrary() {
    final String libName;
    if (Platform.isWindows) {
      libName = 'nebula_core.dll';
    } else if (Platform.isMacOS) {
      libName = 'libnebula_core.dylib';
    } else if (Platform.isIOS) {
      return ffi.DynamicLibrary.process();
    } else {
      libName = 'libnebula_core.so';
    }

    try {
      return ffi.DynamicLibrary.open(libName);
    } catch (_) {
    }

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final String exeDir = p.dirname(Platform.resolvedExecutable);
      
      final searchPaths = [
        exeDir,                                 
        p.join(exeDir, 'lib'),                 
        p.join(exeDir, 'lib64'),               
        p.join(exeDir, 'bundle', 'lib'),       
        p.join(p.dirname(exeDir), 'lib'),      
      ];

      for (final dir in searchPaths) {
        final path = p.join(dir, libName);
        try {
          if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
            return ffi.DynamicLibrary.open(path);
          }
        } catch (_) {
        }
      }
    }

    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open(libName);
    }

    throw UnsupportedError(
        'Could not load $libName. Ensure it is in the system path or app bundle.');
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
      final dbFile = File(dbPath);
      if (!dbFile.parent.existsSync()) {
        dbFile.parent.createSync(recursive: true);
      }

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


  String generateMnemonic() {
    const bufferSize = 256; 
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

  Future<int> checkPassword(String password) async {
    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');
    final dbPathPtr = dbPath.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();

    try {
      final result = _bindings.nebula_check_password(
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

  Future<int> unlockWithPassword(String password) async => checkPassword(password);

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

  int decryptFile(String inputPath, String outputPath, List<int> key, List<int> iv, List<int> tag, List<int> aad) {
    if (iv.length != 12) throw ArgumentError('IV must be exactly 12 bytes');
    if (key.length != 32) throw ArgumentError('Key must be exactly 32 bytes');
    if (tag.length != 16) throw ArgumentError('Tag must be exactly 16 bytes');

    final inputPathPtr = inputPath.toNativeUtf8();
    final outputPathPtr = outputPath.toNativeUtf8();
    final keyPtr = calloc<ffi.Uint8>(key.length);
    final ivPtr = calloc<ffi.Uint8>(iv.length);
    final tagPtr = calloc<ffi.Uint8>(tag.length);
    final aadPtr = calloc<ffi.Uint8>(aad.length);

    try {
      for (int i = 0; i < key.length; i++) keyPtr[i] = key[i];
      for (int i = 0; i < iv.length; i++) ivPtr[i] = iv[i];
      for (int i = 0; i < tag.length; i++) tagPtr[i] = tag[i];
      for (int i = 0; i < aad.length; i++) aadPtr[i] = aad[i];

      return _bindings.aes_decrypt_file(
        inputPathPtr.cast<ffi.Char>(),
        outputPathPtr.cast<ffi.Char>(),
        keyPtr,
        ivPtr,
        tagPtr,
        aadPtr,
        aad.length,
      );
    } finally {
      calloc.free(inputPathPtr);
      calloc.free(outputPathPtr);
      calloc.free(keyPtr);
      calloc.free(ivPtr);
      calloc.free(tagPtr);
      calloc.free(aadPtr);
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

  Uint8List deriveMasterKeyBytes(String mnemonic) {
    final buffer = calloc<ffi.Char>(65); 
    try {
      final result = deriveMasterKey(mnemonic, buffer, 65);
      if (result != 0) {
        throw NebulaError(result, 'Failed to derive master key');
      }
      final hexStr = buffer.cast<Utf8>().toDartString();
      return Uint8List.fromList(hex.decode(hexStr));
    } finally {
      calloc.free(buffer);
    }
  }

  int setSetting(String key, String value) {
    final keyPtr = key.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      return _bindings.nebula_set_setting(
        keyPtr.cast<ffi.Char>(),
        valuePtr.cast<ffi.Char>(),
      );
    } finally {
      calloc.free(keyPtr);
      calloc.free(valuePtr);
    }
  }

  String? getSetting(String key) {
    final keyPtr = key.toNativeUtf8();
    final buffer = calloc<ffi.Char>(4096);
    try {
      final result = _bindings.nebula_get_setting(
        keyPtr.cast<ffi.Char>(),
        buffer,
        4096,
      );
      if (result <= 0) return null;
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(keyPtr);
      calloc.free(buffer);
    }
  }

  int hydrateVfsFromSnapshot(String jsonPath) {
    final pathPtr = jsonPath.toNativeUtf8();
    try {
      return _bindings.hydrate_vfs_from_snapshot(pathPtr.cast<ffi.Char>());
    } finally {
      calloc.free(pathPtr);
    }
  }

  int upsertFolder(String id, String? parentId, String name) {
    final idPtr = id.toNativeUtf8();
    final pIdPtr = parentId?.toNativeUtf8();
    final namePtr = name.toNativeUtf8();
    try {
      return _bindings.nebula_upsert_folder(
        idPtr.cast<ffi.Char>(),
        pIdPtr?.cast<ffi.Char>() ?? ffi.nullptr,
        namePtr.cast<ffi.Char>(),
      );
    } finally {
      calloc.free(idPtr);
      if (pIdPtr != null) calloc.free(pIdPtr);
      calloc.free(namePtr);
    }
  }

  int upsertFile(String id, String? folderId, String name, int size, int manifestMsgId, String? mimeType) {
    final idPtr = id.toNativeUtf8();
    final fIdPtr = folderId?.toNativeUtf8();
    final namePtr = name.toNativeUtf8();
    final mimePtr = mimeType?.toNativeUtf8();
    try {
      return _bindings.nebula_upsert_file(
        idPtr.cast<ffi.Char>(),
        fIdPtr?.cast<ffi.Char>() ?? ffi.nullptr,
        namePtr.cast<ffi.Char>(),
        size,
        manifestMsgId,
        mimePtr?.cast<ffi.Char>() ?? ffi.nullptr,
      );
    } finally {
      calloc.free(idPtr);
      if (fIdPtr != null) calloc.free(fIdPtr);
      calloc.free(namePtr);
      if (mimePtr != null) calloc.free(mimePtr);
    }
  }

  int deleteItem(String id) {
    final idPtr = id.toNativeUtf8();
    try {
      return _bindings.nebula_delete_item(idPtr.cast<ffi.Char>());
    } finally {
      calloc.free(idPtr);
    }
  }

  String listDirectory(String folderId) {
    final folderIdPtr = folderId.toNativeUtf8();
    ffi.Pointer<ffi.Char> resultPtr = ffi.nullptr;
    try {
      resultPtr = _bindings.nebula_list_directory(folderIdPtr.cast());
      if (resultPtr == ffi.nullptr) return '[]';
      return resultPtr.cast<Utf8>().toDartString();
    } finally {
      calloc.free(folderIdPtr);
      if (resultPtr != ffi.nullptr) {
        _bindings.nebula_free_string(resultPtr.cast());
      }
    }
  }

  String exportVfs() {
    ffi.Pointer<ffi.Char> resultPtr = ffi.nullptr;
    try {
      resultPtr = _bindings.nebula_export_vfs();
      if (resultPtr == ffi.nullptr) return '{}';
      return resultPtr.cast<Utf8>().toDartString();
    } finally {
      if (resultPtr != ffi.nullptr) {
        _bindings.nebula_free_string(resultPtr.cast());
      }
    }
  }

  String searchVfs(String query) {
    final queryPtr = query.toNativeUtf8();
    ffi.Pointer<ffi.Char> resultPtr = ffi.nullptr;
    try {
      resultPtr = _bindings.nebula_search_vfs(queryPtr.cast());
      if (resultPtr == ffi.nullptr) return '[]';
      return resultPtr.cast<Utf8>().toDartString();
    } finally {
      calloc.free(queryPtr);
      if (resultPtr != ffi.nullptr) {
        _bindings.nebula_free_string(resultPtr.cast());
      }
    }
  }
}
