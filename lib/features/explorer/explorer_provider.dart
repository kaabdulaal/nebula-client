import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api/nebula_api.dart';
import '../../core/models/file_node.dart';

final explorerProvider = StateNotifierProvider<ExplorerNotifier, List<FileNode>>((ref) {
  return ExplorerNotifier();
});

class ExplorerNotifier extends StateNotifier<List<FileNode>> {
  ExplorerNotifier() : super([]) {
    refresh();
  }

  Future<void> refresh() async {
    if (!NebulaApi.instance.isInitialized) return;

    final indexStr = NebulaApi.instance.getSetting('vfs_index') ?? '[]';
    final List<dynamic> ids = jsonDecode(indexStr);
    
    final List<FileNode> nodes = [];
    for (final id in ids) {
      final nodeStr = NebulaApi.instance.getSetting('vfs_node_$id');
      if (nodeStr != null) {
        try {
          nodes.add(FileNode.fromJson(jsonDecode(nodeStr)));
        } catch (e) {
          print('Error parsing node $id: $e');
        }
      }
    }

    state = nodes;
  }

  Future<void> addNode(FileNode node) async {
    final indexStr = NebulaApi.instance.getSetting('vfs_index') ?? '[]';
    final List<String> ids = List<String>.from(jsonDecode(indexStr));
    
    if (!ids.contains(node.id)) {
      ids.add(node.id);
      NebulaApi.instance.setSetting('vfs_index', jsonEncode(ids));
    }
    
    NebulaApi.instance.setSetting('vfs_node_${node.id}', jsonEncode(node.toJson()));
    await refresh();
  }
}
