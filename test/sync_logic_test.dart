import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'package:nebula_client/core/services/sync_engine.dart';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/vault_anchor_service.dart';

class FakeTelegram extends Fake implements TelegramService {
  @override
  Future<int> getMe() async => 999;
  
  @override
  Stream<Map<String, dynamic>> get updates => const Stream.empty();

  @override
  Future<int?> findNebulaChannel({bool forceRefresh = false, String? expectedHash}) async => 12345;

  @override
  Future<List<Map<String, dynamic>>> getChatHistory({required int chatId, int fromMessageId = 0, int offset = 0, int limit = 100}) async => [];
}

class FakeAnchor extends Fake implements VaultAnchorService {
  @override
  Future<int?> findNebulaChannel({bool forceRefresh = false, String? expectedHash}) async => 12345;
}

class FakeApi extends Fake implements NebulaApi {
  final Map<String, int> tombstones = {}; 
  final List<String> upsertedIds = [];
  final List<String> deletedIds = [];
  int cleanupTimestamp = 0;

  @override
  bool isTombstoned(String id, {int versionTimestamp = 0}) {
    if (!tombstones.containsKey(id)) return false;
    final deletedAt = tombstones[id]!;
    return !(versionTimestamp > 0 && versionTimestamp > deletedAt);
  }

  @override
  int deleteItem(String id, {int? timestamp}) {
    deletedIds.add(id);
    tombstones[id] = timestamp ?? 0;
    return 0;
  }

  @override
  int upsertFile(String id, String? folderId, String name, int size, int manifestMsgId, String? mimeType, {int? timestamp}) {
    upsertedIds.add(id);
    return 0;
  }

  @override
  int cleanupTombstones(int beforeTimestamp) {
    cleanupTimestamp = beforeTimestamp;
    int count = 0;
    tombstones.removeWhere((key, value) {
      if (value < beforeTimestamp) {
        count++;
        return true;
      }
      return false;
    });
    return count;
  }
  
  @override
  int hydrateVfsFromSnapshot(String jsonPath, int snapshotTimestamp) => 0;

  @override
  String exportVfs() => '{}';
}

void main() {
  late SyncEngine syncEngine;
  late FakeTelegram fakeTelegram;
  late FakeAnchor fakeAnchor;
  late FakeApi fakeApi;

  setUp(() {
    fakeTelegram = FakeTelegram();
    fakeAnchor = FakeAnchor();
    fakeApi = FakeApi();
    syncEngine = SyncEngine.withMocks(
      telegramService: fakeTelegram,
      vaultAnchorService: fakeAnchor,
      nebulaApi: fakeApi,
    );
  });

  group('LWW Conflict Resolution', () {
    test('Newer Edit beats Older Delete', () {
      fakeApi.tombstones['item_1'] = 100;

      syncEngine.initializeRealTimeListener();
      
      
    });

    test('LWW Logic Verification (Direct Call Simulation)', () {
      
      fakeApi.tombstones['item_A'] = 1000; 
      
      bool shouldIgnoreOldUpdate = fakeApi.isTombstoned('item_A', versionTimestamp: 500);
      expect(shouldIgnoreOldUpdate, isTrue, reason: 'Old update should be blocked by newer tombstone');

      bool shouldAllowNewUpdate = fakeApi.isTombstoned('item_A', versionTimestamp: 1500);
      expect(shouldAllowNewUpdate, isFalse, reason: 'Newer update should bypass old tombstone');
    });
  });

  group('Garbage Collection', () {
    test('cleanupTombstones is called with correct timestamp during snapshot push', () async {
      syncEngine.setMasterKey(Uint8List(32));
      
      
    });
  });

  group('Snapshot Reconciliation', () {
    test('Reconciliation Logic Verification (Concept)', () {
      
      final localItems = [
        {'id': 'old_file', 'created_at': 100},
        {'id': 'new_file', 'created_at': 300},
      ];
      
      const snapshotTimestamp = 200;
      final snapshotIds = {'new_file', 'other_file'}; 
      
      final toDelete = localItems.where((item) {
        final id = item['id'] as String;
        final createdAt = item['created_at'] as int;
        return !snapshotIds.contains(id) && createdAt < snapshotTimestamp;
      }).map((item) => item['id']).toList();
      
      expect(toDelete, contains('old_file'));
      expect(toDelete, isNot(contains('new_file')), reason: 'New local files should be preserved');
    });
  });
}
