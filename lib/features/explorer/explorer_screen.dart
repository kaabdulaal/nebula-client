import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import '../upload/upload_provider.dart';
import '../upload/upload_button.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';
import './explorer_provider.dart';
import '../../core/models/file_node.dart';
import '../../core/services/sync_engine.dart';
import '../transfers/download_orchestrator.dart';

class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});

  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  final Map<String, double> _downloadProgress = {};
  final DownloadOrchestrator _orchestrator = DownloadOrchestrator();

  @override
  void initState() {
    super.initState();
    _orchestrator.progressStream.listen((event) {
      if (mounted) {
        setState(() {
          _downloadProgress.addAll(event);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(explorerProvider);
    final syncEngine = ref.watch(syncEngineProvider);
    
    // Listen for auth state changes
    ref.listen(authProvider, (previous, next) {
      if (next.status == AuthStateStatus.initial) {
        print('[Explorer] Auth initial detected. Redirecting to Onboarding.');
        context.go('/onboarding');
      }
    });

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: ref.watch(explorerProvider.notifier).isSelectionMode
            ? Text('${ref.watch(explorerProvider.notifier).selectedIds.length} Selected')
            : Text(ref.watch(explorerProvider.notifier).currentFolderName),
        leading: ref.watch(explorerProvider.notifier).isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(explorerProvider.notifier).clearSelection(),
              )
            : (ref.watch(explorerProvider.notifier).canGoBack
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => ref.read(explorerProvider.notifier).goBack(),
                  )
                : null),
        backgroundColor: Colors.transparent,
        elevation: 0,
        bottom: syncEngine.isSyncing 
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                minHeight: 2,
              ),
            )
          : null,
        actions: ref.watch(explorerProvider.notifier).isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.delete_forever, color: Colors.red, size: 28),
                  onPressed: () => _confirmDelete(context, ref),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => ref.read(explorerProvider.notifier).refresh(),
                ),
                IconButton(
                  icon: const Icon(Icons.logout),
                  onPressed: () {
                     NebulaApi.instance.cleanup();
                     context.go('/login');
                  },
                ),
              ],
      ),
      body: Column(
        children: [
          // Breadcrumbs Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            width: double.infinity,
            color: Colors.white.withOpacity(0.02),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(Icons.home, size: 16, color: Colors.blueAccent),
                  const SizedBox(width: 8),
                  Text(
                    ref.watch(explorerProvider.notifier).currentPath.isEmpty 
                        ? 'Root' 
                        : 'Root > ${ref.watch(explorerProvider.notifier).currentPath}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search Vault...',
                hintStyle: const TextStyle(color: Colors.white24),
                prefixIcon: const Icon(Icons.search, color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (value) {
                ref.read(explorerProvider.notifier).search(value);
              },
            ),
          ),
          Expanded(
            child: files.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.folder_open,
                      size: 64, color: Colors.white24),
                  const SizedBox(height: 16),
                  const Text(
                    'Vault is empty',
                    style: TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: files.length,
              itemBuilder: (context, index) {
                final node = files[index];
                final isFolder = node.type == FileNodeType.folder;
                final isSelected = ref.watch(explorerProvider.notifier).selectedIds.contains(node.id);
                
                return ListTile(
                  selected: isSelected,
                  selectedTileColor: Colors.blue.withOpacity(0.1),
                  leading: ref.watch(explorerProvider.notifier).isSelectionMode
                    ? Icon(
                        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: Colors.blue,
                      )
                    : Icon(
                        isFolder ? Icons.folder : Icons.insert_drive_file,
                        color: isFolder ? Colors.amber : Colors.blue,
                      ),
                  title: Text(node.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                  subtitle: Text(
                    isFolder 
                        ? 'Folder' 
                        : '${(node.size / 1024).toStringAsFixed(1)} KB • ${node.syncStatus.name}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  trailing: ref.watch(explorerProvider.notifier).isSelectionMode
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isFolder)
                            IconButton(
                              icon: const Icon(Icons.download, color: Colors.white38, size: 20),
                              onPressed: () => _handleDownload(context, node),
                            ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.white24, size: 20),
                            onPressed: () => _confirmSingleDelete(context, ref, node),
                          ),
                        ],
                      ),
                  onTap: () {
                    final notifier = ref.read(explorerProvider.notifier);
                    if (notifier.isSelectionMode) {
                      notifier.toggleSelection(node.id);
                    } else if (isFolder) {
                      notifier.navigateToFolder(node.id, node.name);
                    }
                  },
                  onLongPress: () {
                    ref.read(explorerProvider.notifier).toggleSelection(node.id);
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.blueAccent,
        onPressed: () => _showActionSheet(context, ref),
        child: const Icon(Icons.add, size: 32),
      ),
    );
  }

  void _showActionSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222222),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder, color: Colors.amber),
              title: const Text('New Folder', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _createFolderDialog(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file, color: Colors.blue),
              title: const Text('Upload File', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _handleUpload(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _handleDownload(BuildContext context, FileNode node) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Downloading ${node.name}...')),
    );
    
    try {
      await _orchestrator.startDownload(node);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      if (e.toString().contains('USER_CANCELLED')) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Download failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _confirmSingleDelete(BuildContext context, WidgetRef ref, FileNode node) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('Delete Item', style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to delete ${node.name}?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              ref.read(explorerProvider.notifier).deleteItem(node.id);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleUpload(BuildContext context, WidgetRef ref) async {
    try {
      final notifier = ref.read(explorerProvider.notifier);
      final result = await FilePicker.platform.pickFiles();
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        await ref.read(activeUploadsProvider.notifier).startUpload(
              sourceFile: file,
              parentId: notifier.currentFolderId,
            );
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload started...')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  void _createFolderDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('New Folder', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Folder Name',
            hintStyle: TextStyle(color: Colors.white24),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                ref.read(explorerProvider.notifier).createFolder(controller.text);
              }
              Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    final count = ref.read(explorerProvider.notifier).selectedIds.length;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('Confirm Delete', style: TextStyle(color: Colors.white)),
        content: Text('Delete $count selected items?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              ref.read(explorerProvider.notifier).deleteSelected();
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
