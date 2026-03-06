import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nebula_client/core/api/nebula_api.dart';
import 'package:nebula_client/core/models/file_node.dart';
import 'package:nebula_client/core/services/sync_engine.dart';
import 'package:nebula_client/core/services/thumbnail_service.dart';
import 'package:nebula_client/core/services/telegram_service.dart';
import 'package:nebula_client/core/services/event_bus.dart';

final syncEngineProvider = ChangeNotifierProvider<SyncEngine>((ref) {
  return SyncEngine();
});

class ExplorerState {
  final List<FileNode> files;
  final bool isLoading;
  final String currentFolderId;
  final String currentFolderName;
  final List<String> navigationStack;
  final Set<String> selectedIds;
  final Map<String, String> folderNames;
  final Map<String, Uint8List> thumbnails;

  const ExplorerState({
    required this.files,
    this.isLoading = false,
    required this.currentFolderId,
    required this.currentFolderName,
    required this.navigationStack,
    required this.selectedIds,
    required this.folderNames,
    this.thumbnails = const {},
  });

  bool get isSelectionMode => selectedIds.isNotEmpty;
  bool get canGoBack => navigationStack.isNotEmpty || currentFolderId != 'root';

  String get currentPath =>
      navigationStack.map((id) => folderNames[id] ?? '...').join(' > ');

  ExplorerState copyWith({
    List<FileNode>? files,
    bool? isLoading,
    String? currentFolderId,
    String? currentFolderName,
    List<String>? navigationStack,
    Set<String>? selectedIds,
    Map<String, String>? folderNames,
    Map<String, Uint8List>? thumbnails,
  }) {
    return ExplorerState(
      files: files ?? this.files,
      isLoading: isLoading ?? this.isLoading,
      currentFolderId: currentFolderId ?? this.currentFolderId,
      currentFolderName: currentFolderName ?? this.currentFolderName,
      navigationStack: navigationStack ?? this.navigationStack,
      selectedIds: selectedIds ?? this.selectedIds,
      folderNames: folderNames ?? this.folderNames,
      thumbnails: thumbnails ?? this.thumbnails,
    );
  }
}

final explorerProvider = StateNotifierProvider<ExplorerNotifier, ExplorerState>((ref) {
  final notifier = ExplorerNotifier();
  Timer? debounce;
  ref.listen(syncEngineProvider, (previous, next) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () {
      notifier.refresh();
    });
  });
  ref.onDispose(() => debounce?.cancel());
  return notifier;
});

class ExplorerNotifier extends StateNotifier<ExplorerState> {
  bool _isNavigating = false; 

  ExplorerNotifier() : super(const ExplorerState(
    files: [],
    currentFolderId: 'root',
    currentFolderName: 'Root',
    navigationStack: [],
    selectedIds: {},
    folderNames: {'root': 'Root'},
  )) {
    _initRefresh();
    _setupEventListeners();
  }

  void _setupEventListeners() {
    EventBus().on<FileUploadedEvent>().listen((event) {
      if (event.node.parentId == state.currentFolderId || 
          (event.node.parentId == 'root' && state.currentFolderId == 'root')) {
        _log('Reactive Update: Optimistically adding ${event.node.name} to view.');
        
        final existing = state.files.any((f) => f.id == event.node.id);
        if (!existing) {
          final newFiles = [...state.files, event.node];
          newFiles.sort((a, b) {
            if (a.type != b.type) return a.type == FileNodeType.folder ? -1 : 1;
            return a.name.compareTo(b.name);
          });
          state = state.copyWith(files: newFiles);
        }
      }
    });
  }


  String get currentFolderId => state.currentFolderId;
  Set<String> get selectedIds => state.selectedIds;
  bool get isSelectionMode => state.isSelectionMode;
  bool get canGoBack => state.canGoBack;
  String get currentPath => state.currentPath;
  String get currentFolderName => state.currentFolderName;

  Future<void> navigateToFolder(String id, String name) async {
    if (_isNavigating) return; 
    _isNavigating = true;
    try {
      final newStack = [...state.navigationStack, state.currentFolderId];
      final newNames = {...state.folderNames, id: name};
      state = state.copyWith(
        currentFolderId: id,
        currentFolderName: name,
        navigationStack: newStack,
        folderNames: newNames,
        selectedIds: {},
        isLoading: true,
      );
      await _fetchDirectory(id);
    } finally {
      _isNavigating = false;
    }
  }

  void toggleSelection(String id) {
    final current = {...state.selectedIds};
    if (current.contains(id)) {
      current.remove(id);
    } else {
      current.add(id);
    }
    state = state.copyWith(selectedIds: current);
  }

  void clearSelection() {
    state = state.copyWith(selectedIds: {});
  }

  Future<void> _initRefresh() async {
    for (int i = 0; i < 5; i++) {
       if (NebulaApi.instance.isInitialized) break;
       await Future.delayed(const Duration(milliseconds: 500));
    }
    await refresh();
  }

  Future<void> refresh({String? folderId, String? folderName}) async {
    if (!NebulaApi.instance.isInitialized) return;

    if (folderId != null && folderId != state.currentFolderId) {
      await navigateToFolder(folderId, folderName ?? folderId);
      return;
    }
    
    state = state.copyWith(isLoading: true);
    await _fetchDirectory(state.currentFolderId);
  }

  Future<void> _fetchDirectory(String folderId) async {
    try {
      final jsonStr = NebulaApi.instance.listDirectory(folderId);
      final nodes = await compute(_parseFileNodes, jsonStr);
      state = state.copyWith(files: nodes, isLoading: false);
    } catch (e) {
      _log('Directory listing failed: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> createFolder(String name) async {
    try {
      final serverTime = TelegramService.instance.serverTime;
      final serverDateTime = DateTime.fromMillisecondsSinceEpoch(serverTime * 1000);
      
      final id = 'folder_${serverTime}_${DateTime.now().millisecondsSinceEpoch % 1000}';
      NebulaApi.instance.upsertFolder(id, state.currentFolderId, name, timestamp: serverTime);
      
      final node = FileNode(
        id: id,
        name: name,
        parentId: state.currentFolderId,
        type: FileNodeType.folder,
        size: 0,
        syncStatus: SyncStatus.synced,
        mimeType: 'application/octet-stream',
        createdAt: serverDateTime,
        modifiedAt: serverDateTime,
      );

      await SyncEngine().broadcastManifest(node);
      SyncEngine().scheduleAutoPush();
      await refresh();
    } catch (e) {
      _log('Create folder failed: $e');
    }
  }

  Future<void> deleteSelected() async {
    if (state.selectedIds.isEmpty) return;
    
    final idsToRemove = state.selectedIds.toList();
    state = state.copyWith(
      files: state.files.where((node) => !idsToRemove.contains(node.id)).toList(),
      selectedIds: {},
    );

    try {
      _log('Bulk Deleting ${idsToRemove.length} items...');
      
      for (final id in idsToRemove) {
        NebulaApi.instance.deleteItem(id);
      }

      await SyncEngine().broadcastBulkTombstone(idsToRemove);
      SyncEngine().scheduleAutoPush();
    } catch (e) {
      _log('Bulk delete failed: $e');
      await refresh(); 
    }
  }

  Future<int> moveSelected(String targetFolderId) async {
    if (state.selectedIds.isEmpty) return 0;

    final idsToMove = state.selectedIds.toList();
    int moved = 0;
    bool cyclicDetected = false;

    final serverTime = TelegramService.instance.serverTime;
    final serverDateTime = DateTime.fromMillisecondsSinceEpoch(serverTime * 1000);

    for (final id in idsToMove) {
      final rc = NebulaApi.instance.updateItemParent(id, targetFolderId, timestamp: serverTime);
      if (rc == 0) {
        moved++;
        final node = state.files.firstWhere(
          (n) => n.id == id,
          orElse: () => FileNode(
            id: id, parentId: targetFolderId, type: FileNodeType.file,
            syncStatus: SyncStatus.synced, name: '', size: 0,
            mimeType: '', createdAt: serverDateTime, modifiedAt: serverDateTime,
          ),
        );
        final updatedNode = FileNode(
          id: node.id,
          parentId: targetFolderId,
          type: node.type,
          syncStatus: node.syncStatus,
          name: node.name,
          size: node.size,
          mimeType: node.mimeType,
          manifestMsgId: node.manifestMsgId,
          createdAt: node.createdAt,
          modifiedAt: serverDateTime,
        );
        await SyncEngine().broadcastManifest(updatedNode);
      } else if (rc == -2) {
        cyclicDetected = true;
      }
    }

    state = state.copyWith(selectedIds: {});
    SyncEngine().scheduleAutoPush();
    await refresh();

    if (cyclicDetected) return -2;
    return moved;
  }

  Future<void> search(String query) async {
    if (query.isEmpty) {
      await refresh();
      return;
    }

    state = state.copyWith(isLoading: true);
    try {
      final jsonStr = NebulaApi.instance.searchVfs(query);
      final nodes = await compute(_parseFileNodes, jsonStr);
      state = state.copyWith(files: nodes, isLoading: false);
    } catch (e) {
      _log('Search failed: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> jumpToFolder(String id) async {
    if (_isNavigating || id == state.currentFolderId) return;
    _isNavigating = true;
    try {
      final index = state.navigationStack.indexOf(id);
      List<String> newStack;
      if (id == 'root') {
        newStack = [];
      } else if (index != -1) {
        newStack = state.navigationStack.sublist(0, index);
      } else {
        newStack = [];
        id = 'root';
      }

      state = state.copyWith(
        currentFolderId: id,
        currentFolderName: state.folderNames[id] ?? (id == 'root' ? 'Root' : 'Folder'),
        navigationStack: newStack,
        isLoading: true,
        selectedIds: {},
      );
      await _fetchDirectory(id);
    } finally {
      _isNavigating = false;
    }
  }

  Future<void> goBack() async {
    if (_isNavigating) return;
    _isNavigating = true;
    try {
      if (state.navigationStack.isEmpty) {
        if (state.currentFolderId != 'root') {
          state = state.copyWith(
            currentFolderId: 'root',
            currentFolderName: 'Root',
            selectedIds: {},
            isLoading: true,
          );
          await _fetchDirectory('root');
        }
        return;
      }
      final newStack = [...state.navigationStack];
      final previousId = newStack.removeLast();
      state = state.copyWith(
        currentFolderId: previousId,
        currentFolderName: state.folderNames[previousId] ?? 'Root',
        navigationStack: newStack,
        selectedIds: {},
        isLoading: true,
      );
      await _fetchDirectory(previousId);
    } finally {
      _isNavigating = false;
    }
  }

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
      
      await SyncEngine().broadcastManifest(node);
    } catch (e) {
      _log('addNode failed: $e');
    }
    SyncEngine().scheduleAutoPush();
    await refresh();
  }

  Future<void> deleteItem(String id) async {
    state = state.copyWith(
      files: state.files.where((node) => node.id != id).toList(),
    );

    try {
      NebulaApi.instance.deleteItem(id);
      SyncEngine().broadcastTombstone(id);
      SyncEngine().scheduleAutoPush();
    } catch (e) {
      _log('deleteItem failed: $e');
      await refresh();
    }
  }

  Future<void> loadThumbnail(FileNode node) async {
    if (state.thumbnails.containsKey(node.id)) return;
    
    final bytes = await ThumbnailService().getThumbnail(node);
    if (bytes != null) {
      if (mounted) {
        state = state.copyWith(
          thumbnails: {...state.thumbnails, node.id: bytes},
        );
      }
    }
  }

  void _log(String message) {
    if (kDebugMode) {
      print('[ExplorerNotifier] $message');
    }
  }
}

List<FileNode> _parseFileNodes(String jsonStr) {
  final List<dynamic> decoded = jsonDecode(jsonStr);
  return decoded.map((item) {
    return FileNode.fromSqlJson(Map<String, dynamic>.from(item));
  }).toList();
}
