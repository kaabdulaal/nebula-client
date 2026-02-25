import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/nebula_api.dart';
import '../../core/models/file_node.dart';
import '../../core/services/sync_engine.dart';

final syncEngineProvider = ChangeNotifierProvider<SyncEngine>((ref) {
  return SyncEngine();
});

final explorerProvider = StateNotifierProvider<ExplorerNotifier, List<FileNode>>((ref) {
  final notifier = ExplorerNotifier();
  // Listen for background sync updates to refresh UI instantly
  ref.listen(syncEngineProvider, (previous, next) {
    notifier.refresh();
  });
  return notifier;
});

class ExplorerNotifier extends StateNotifier<List<FileNode>> {
  String _currentFolderId = 'root';
  String get currentFolderId => _currentFolderId;

  final List<String> _navigationStack = [];
  final Map<String, String> _folderNames = {'root': 'Root'};

  final Set<String> _selectedIds = {};
  Set<String> get selectedIds => _selectedIds;
  bool get isSelectionMode => _selectedIds.isNotEmpty;

  bool get canGoBack => _navigationStack.isNotEmpty;
  String get currentPath => _navigationStack.map((id) => _folderNames[id] ?? '...').join(' > ');
  String get currentFolderName => _folderNames[_currentFolderId] ?? 'Root';

  ExplorerNotifier() : super([]) {
    _initRefresh();
  }

  Future<void> navigateToFolder(String id, String name) async {
    await refresh(folderId: id, folderName: name);
  }

  void toggleSelection(String id) {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
    state = List.from(state); // Trigger UI update
  }

  void clearSelection() {
    _selectedIds.clear();
    state = List.from(state);
  }

  Future<void> _initRefresh() async {
    // Retry bridge initialization if needed
    for (int i = 0; i < 5; i++) {
       if (NebulaApi.instance.isInitialized) break;
       await Future.delayed(const Duration(milliseconds: 500));
    }
    await refresh();
  }

  Future<void> refresh({String? folderId, String? folderName}) async {
    if (!NebulaApi.instance.isInitialized) return;
    
    if (folderId != null && folderId != _currentFolderId) {
      if (_currentFolderId != 'root' || folderId != 'root') {
         _navigationStack.add(_currentFolderId);
      }
      _currentFolderId = folderId;
      if (folderName != null) _folderNames[folderId] = folderName;
      _selectedIds.clear(); // Clear selection on navigate
    }

    final jsonStr = NebulaApi.instance.listDirectory(_currentFolderId);
    final List<dynamic> decoded = jsonDecode(jsonStr);
    
    final List<FileNode> nodes = decoded.map((item) {
      return FileNode.fromSqlJson(Map<String, dynamic>.from(item));
    }).toList();

    state = nodes;
  }

  Future<void> createFolder(String name) async {
    try {
      final id = 'folder_${DateTime.now().millisecondsSinceEpoch}';
      NebulaApi.instance.upsertFolder(id, _currentFolderId, name);
      SyncEngine().scheduleAutoPush();
      await refresh();
    } catch (e) {
      print('[Explorer] Create folder failed: $e');
    }
  }

  Future<void> deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    
    final idsToRemove = _selectedIds.toList();
    _selectedIds.clear();

    // Optimistic UI update
    state = state.where((node) => !idsToRemove.contains(node.id)).toList();

    try {
      _log('Bulk Deleting ${idsToRemove.length} items...');
      
      // 1. Core Deletion
      for (final id in idsToRemove) {
        NebulaApi.instance.deleteItem(id);
      }

      // 2. Cloud Broadcast (Optimized)
      await SyncEngine().broadcastBulkTombstone(idsToRemove);

      // 3. Schedule Snapshot
      SyncEngine().scheduleAutoPush();
    } catch (e) {
      print('[Explorer] Bulk delete failed: $e');
      await refresh(); // Revert on failure
    }
  }

  Future<void> search(String query) async {
    if (query.isEmpty) {
      await refresh();
      return;
    }

    final jsonStr = NebulaApi.instance.searchVfs(query);
    final List<dynamic> decoded = jsonDecode(jsonStr);
    
    final List<FileNode> nodes = decoded.map((item) {
      return FileNode.fromSqlJson(Map<String, dynamic>.from(item));
    }).toList();

    state = nodes;
  }

  Future<void> goBack() async {
    if (_navigationStack.isEmpty) {
      if (_currentFolderId != 'root') {
        _currentFolderId = 'root';
        await refresh();
      }
      return;
    }
    _currentFolderId = _navigationStack.removeLast();
    _selectedIds.clear(); // Clear selection on navigate
    await refresh();
  }

  // Legacy support for addNode (needs translation to SQL)
  Future<void> addNode(FileNode node) async {
    try {
      if (node.type == FileNodeType.folder) {
        NebulaApi.instance.upsertFolder(node.id, node.parentId, node.name);
      } else {
        NebulaApi.instance.upsertFile(
          node.id, 
          node.parentId, 
          node.name, 
          node.size, 
          node.manifestMsgId ?? 0, 
          node.mimeType
        );
      }
    } catch (e) {
      print('[Explorer] addNode failed: $e');
    }
    SyncEngine().scheduleAutoPush();
    await refresh();
  }

  Future<void> deleteItem(String id) async {
    // Optimistic UI update
    state = state.where((node) => node.id != id).toList();

    try {
      NebulaApi.instance.deleteItem(id);
      SyncEngine().broadcastTombstone(id);
      SyncEngine().scheduleAutoPush();
    } catch (e) {
      print('[Explorer] deleteItem failed: $e');
      await refresh();
    }
  }

  void _log(String message) {
    print('[ExplorerNotifier] $message');
  }
}
