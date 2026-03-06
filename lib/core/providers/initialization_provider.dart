import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../api/nebula_api.dart';

enum InitializationStatus {
  uninitialized,
  loading,
  ready, 
  needsOnboarding, 
  needsAuth, 
  needsCartridge, 
  error,
}

final initializationProvider =
    FutureProvider<InitializationStatus>((ref) async {
  try {
    final docsDir = await getNebulaDocumentsDirectory();
    final dbPath = p.join(docsDir.path, 'nebula.db');

    final dbFile = File(dbPath);
    final exists = await dbFile.exists();

    if (!exists) {
      return InitializationStatus.needsOnboarding;
    }

    return InitializationStatus.needsAuth;
  } catch (e) {
    rethrow;
  }
});
