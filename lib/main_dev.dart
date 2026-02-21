import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_bootstrap.dart';
import 'core/api/nebula_api.dart';
import 'core/config/app_config.dart';

void main() {
  final config = AppConfig.dev();

  final api = NebulaApi();
  int initResult = -1;
  String version = 'unknown';

  try {
    version = api.version();
    initResult = api.init();
  } catch (e) {
    debugPrint('❌ Critical Error: Failed to load Nebula Core: $e');
  }

  if (config.enableLogging && kDebugMode) {
    debugPrint(
        '🚀 Nebula starting in ${config.flavor.name.toUpperCase()} mode');
    debugPrint('   API: ${config.apiBaseUrl}');
    debugPrint('🌌 Nebula Core Version: $version');
  }

  if (initResult != 0) {
    debugPrint('❌ Nebula Core initialization failed with code: $initResult');
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'Critical System Error',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Nebula Core failed to initialize (Code: $initResult).',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Please check your native library configuration.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }

  debugPrint('✅ Nebula Core initialized successfully');
  bootstrap(config);
}
