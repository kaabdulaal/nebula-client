import 'package:flutter_test/flutter_test.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'dart:io';

void main() {
  test('C++ Crypto Wrap/Unwrap Test', () async {
    final dbPath = '${Directory.systemTemp.path}/test_nebula.db';
    final dbFile = File(dbPath);
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }
    
    final mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    final password = 'mySecurePassword123';

    final setupResult = await NebulaApi.instance.setPassword(dbPath, mnemonic, password);
    expect(setupResult, 0, reason: 'Setup should succeed');

    final unlockResult = await NebulaApi.instance.unlockWithPassword(dbPath, password);
    
    expect(unlockResult, 0, reason: 'Unlock should succeed but returns $unlockResult');
  });
}
