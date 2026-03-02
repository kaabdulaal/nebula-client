import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/api/nebula_api.dart';
import '../../core/models/file_node.dart';

/// A modal bottom sheet that lets the user pick a destination folder.
/// Excludes items in [excludeIds] to prevent moving a folder into itself.
class FolderPickerDialog extends StatefulWidget {
  final Set<String> excludeIds;

  const FolderPickerDialog({super.key, required this.excludeIds});

  /// Shows the dialog and returns the selected folder ID, or null if cancelled.
  static Future<String?> show(BuildContext context, {required Set<String> excludeIds}) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => FolderPickerDialog(excludeIds: excludeIds),
    );
  }

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  String _currentFolderId = 'root';
  String _currentFolderName = 'Root';
  List<FileNode> _folders = [];
  final List<String> _navStack = [];
  final List<String> _navNames = [];

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  void _loadFolders() {
    try {
      final jsonStr = NebulaApi.instance.listDirectory(_currentFolderId);
      final list = jsonDecode(jsonStr) as List;
      final nodes = list
          .map((e) => FileNode.fromSqlJson(e as Map<String, dynamic>))
          .where((n) => n.type == FileNodeType.folder && !widget.excludeIds.contains(n.id))
          .toList();
      setState(() => _folders = nodes);
    } catch (e) {
      setState(() => _folders = []);
    }
  }

  void _navigateInto(FileNode folder) {
    _navStack.add(_currentFolderId);
    _navNames.add(_currentFolderName);
    _currentFolderId = folder.id;
    _currentFolderName = folder.name;
    _loadFolders();
  }

  void _goBack() {
    if (_navStack.isEmpty) return;
    _currentFolderId = _navStack.removeLast();
    _currentFolderName = _navNames.removeLast();
    _loadFolders();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              if (_navStack.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white70),
                  onPressed: _goBack,
                ),
              Expanded(
                child: Text(
                  'Move to: $_currentFolderName',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, _currentFolderId),
                child: const Text('Move Here', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const Divider(color: Colors.white12),

          // Folder list
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: _folders.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No subfolders', style: TextStyle(color: Colors.white38)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return ListTile(
                        leading: const Icon(Icons.folder, color: Colors.amber),
                        title: Text(folder.name, style: const TextStyle(color: Colors.white)),
                        trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                        onTap: () => _navigateInto(folder),
                      );
                    },
                  ),
          ),

          const SizedBox(height: 8),
          // Cancel
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
          ),
        ],
      ),
    );
  }
}
