import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../api/nebula_api.dart';

enum InitializationStatus {
  uninitialized,
  loading,
  ready, // Vault is unlocked and credentials injected
  needsOnboarding, // No database exists
  needsAuth, // Database exists but locked
  needsCartridge, // Database unlocked but no API keys
  error,
}

final initializationProvider =
    FutureProvider<InitializationStatus>((ref) async {
  try {
    // 1. Get Application Documents Directory (platform-aware via nebula_api.dart)
    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');

    final dbFile = File(dbPath);
    final exists = await dbFile.exists();

    if (!exists) {
      return InitializationStatus.needsOnboarding;
    }

    return InitializationStatus.needsAuth;
  } catch (e) {
    throw e;
  }
});
