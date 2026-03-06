import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import '../upload/upload_provider.dart';
import '../../core/auth/auth_provider.dart';
import './explorer_provider.dart';
import './folder_picker_dialog.dart';
import '../../core/models/file_node.dart';
import '../transfers/download_orchestrator.dart';
import '../../core/services/transfer_service.dart';
import '../../core/models/transfer_progress.dart';
import '../../core/utils/format_utils.dart';

({IconData icon, Color color}) _getFileIcon(FileNode node) {
  if (node.isImage) {
    return (icon: Icons.image, color: Colors.green);
  }
  if (node.isVideo) {
    return (icon: Icons.videocam, color: Colors.purple);
  }
  if (node.isAudio) {
    return (icon: Icons.audiotrack, color: Colors.teal);
  }
  if (node.isPdf) {
    return (icon: Icons.picture_as_pdf, color: Colors.red);
  }
  if (node.isArchive) {
    return (icon: Icons.archive, color: Colors.orange);
  }
  return (icon: Icons.insert_drive_file, color: Colors.blue);
}

class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});

  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  @override
  void initState() {
    super.initState();
  }

  String _buildSafeSubtitle(FileNode node) {
    try {
      final sizeStr = NebulaFormatUtils.formatBytes(node.size);
      String status;
      try {
        status = node.syncStatus.label;
      } catch (_) {
        status = 'Synced';
      }
      return '$sizeStr • $status';
    } catch (e) {
      return NebulaFormatUtils.formatBytes(node.size);
    }
  }

  Widget _buildLeading(
      FileNode node,
      bool isSelected,
      bool isSelectionMode,
      TransferProgress? transfer,
      ExplorerState state,
      ExplorerNotifier notifier) {
    if (isSelectionMode) {
      return Icon(
        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: Colors.blue,
      );
    }

    if (transfer != null) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: transfer.progress,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
        ),
      );
    }

    if (node.type == FileNodeType.folder) {
      return const Icon(Icons.folder, color: Colors.amber);
    }

    if (node.isImage) {
      return _ThumbnailWidget(node: node);
    }

    final meta = _getFileIcon(node);
    return Icon(meta.icon, color: meta.color);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(explorerProvider);
    final notifier = ref.read(explorerProvider.notifier);
    final files = state.files;
    final isLoading = state.isLoading;
    final isSelectionMode = state.isSelectionMode;
    final selectedIds = state.selectedIds;
    final canGoBack = state.canGoBack;
    final currentFolderId = state.currentFolderId;
    final showGlobalProgress = ref.watch(syncEngineProvider.select((s) => s.showGlobalProgress));
    final transfers = ref.watch(transferServiceProvider);
    final isNotRoot = currentFolderId != 'root';
    

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: isSelectionMode
            ? Text('${selectedIds.length} Selected')
            : const _BreadcrumbWidget(),
        leading: isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(explorerProvider.notifier).clearSelection(),
              )
            : (canGoBack
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => ref.read(explorerProvider.notifier).goBack(),
                  )
                : null),
        backgroundColor: Colors.transparent,
        elevation: 0,
        bottom: (showGlobalProgress || isLoading)
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                minHeight: 2,
              ),
            )
          : null,
        actions: isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.drive_file_move, color: Colors.blueAccent, size: 28),
                  tooltip: 'Move to folder',
                  onPressed: () => _handleMove(context),
                ),
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
                  icon: const Icon(Icons.settings),
                  onPressed: () => context.push('/api_settings'),
                ),
                IconButton(
                  icon: const Icon(Icons.logout),
                  onPressed: () => ref.read(authProvider.notifier).lockVault(),
                ),
              ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search Vault...',
                hintStyle: const TextStyle(color: Colors.white24),
                prefixIcon: const Icon(Icons.search, color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
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
            child: files.isEmpty && !isLoading
          ? Center(
              child: Opacity(
                opacity: 0.5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(isNotRoot ? Icons.folder_open : Icons.cloud_off,
                        size: 80, color: Colors.blueAccent),
                    const SizedBox(height: 16),
                    Text(
                      isNotRoot ? 'This folder is empty' : 'Vault is empty',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              itemCount: files.length,
              itemBuilder: (context, index) {
                final node = files[index];
                final isFolder = node.type == FileNodeType.folder;
                final isSelected = selectedIds.contains(node.id);
                final transfer = transfers[node.id];
                final isTransferring = transfer != null;

                return ListTile(
                  selected: isSelected,
                  selectedTileColor: Colors.blue.withValues(alpha: 0.1),
                  leading: _buildLeading(node, isSelected, isSelectionMode, transfer, state, notifier),
                  title: Text(node.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isFolder 
                            ? 'Folder' 
                            : (isTransferring 
                                ? '${transfer.statusLabel ?? (transfer.type == TransferType.upload ? 'Uploading' : 'Downloading')}... ${(transfer.progress * 100).toStringAsFixed(0)}%'
                                : _buildSafeSubtitle(node)),
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      if (isTransferring)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: LinearProgressIndicator(
                            value: transfer.progress,
                            minHeight: 2,
                            backgroundColor: Colors.white10,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                          ),
                        ),
                    ],
                  ),
                  trailing: isSelectionMode || isTransferring
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
                _handleUpload(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _handleDownload(BuildContext context, FileNode node) async {
    final orchestrator = DownloadOrchestrator();
    final messenger = ScaffoldMessenger.of(context); 
    
    try {
      await orchestrator.startDownload(
        node,
        onProgress: (p) {
          if (!mounted) return;
          ref.read(transferServiceProvider.notifier).updateDownload(node.id, node.name, p);
        },
      );
      
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Downloaded ${node.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      if (e.toString() != 'Exception: USER_CANCELLED') {
        messenger.showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        ref.read(transferServiceProvider.notifier).updateDownload(node.id, node.name, 1.0);
      }
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
              final messenger = ScaffoldMessenger.of(context); 
              ref.read(explorerProvider.notifier).deleteItem(node.id);
              Navigator.pop(context);
              if (!mounted) return;
              messenger.showSnackBar(
                SnackBar(content: Text('${node.name} deleted')),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleUpload(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context); 
    try {
      final notifier = ref.read(explorerProvider.notifier);
      final result = await FilePicker.platform.pickFiles();
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        
        if (!mounted) return;
        
        await ref.read(activeUploadsProvider.notifier).startUpload(
              sourceFile: file,
              parentId: notifier.currentFolderId,
            );
        
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Upload started...')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
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
              final messenger = ScaffoldMessenger.of(context); 
              final count = ref.read(explorerProvider.notifier).selectedIds.length;
              ref.read(explorerProvider.notifier).deleteSelected();
              Navigator.pop(context);
              if (!mounted) return;
              messenger.showSnackBar(
                SnackBar(content: Text('$count items deleted')),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleMove(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context); 
    final selectedIds = ref.read(explorerProvider).selectedIds;
    if (selectedIds.isEmpty) return;

    final targetFolderId = await FolderPickerDialog.show(
      context,
      excludeIds: selectedIds,
    );

    if (targetFolderId == null || !mounted) return;

    final result = await ref.read(explorerProvider.notifier).moveSelected(targetFolderId);
    if (!mounted) return;

    if (result == -2) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Cannot move a folder into itself or its subfolder.'),
          backgroundColor: Colors.red,
        ),
      );
    } else if (result > 0) {
      messenger.showSnackBar(
        SnackBar(content: Text('$result item(s) moved successfully.')),
      );
    }
  }
}

class _BreadcrumbWidget extends ConsumerWidget {
  const _BreadcrumbWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(explorerProvider);
    final stack = state.navigationStack;
    final folderNames = state.folderNames;
    
    List<Widget> crumbs = [];
    
    crumbs.add(
      _Crumb(
        name: 'Root',
        isLast: stack.isEmpty && state.currentFolderId == 'root',
        onTap: () => ref.read(explorerProvider.notifier).jumpToFolder('root'),
      ),
    );
    
    for (int i = 0; i < stack.length; i++) {
        final id = stack[i];
        if (id == 'root') continue; 
        crumbs.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2.0),
          child: Icon(Icons.chevron_right, size: 16, color: Colors.white24),
        ));
        crumbs.add(
          _Crumb(
            name: folderNames[id] ?? 'Folder',
            isLast: false,
            onTap: () => ref.read(explorerProvider.notifier).jumpToFolder(id),
          ),
        );
    }
    
    if (state.currentFolderId != 'root') {
      crumbs.add(const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2.0),
        child: Icon(Icons.chevron_right, size: 16, color: Colors.white24),
      ));
      crumbs.add(
        _Crumb(
          name: state.currentFolderName,
          isLast: true,
          onTap: null, 
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: crumbs),
    );
  }
}

class _Crumb extends StatelessWidget {
  final String name;
  final bool isLast;
  final VoidCallback? onTap;

  const _Crumb({required this.name, required this.isLast, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
        child: Text(
          name,
          style: TextStyle(
            color: isLast ? Colors.white : Colors.blueAccent,
            fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
class _ThumbnailWidget extends ConsumerStatefulWidget {
  final FileNode node;
  const _ThumbnailWidget({required this.node});

  @override
  ConsumerState<_ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends ConsumerState<_ThumbnailWidget> {
  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  void _loadThumbnail() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(explorerProvider.notifier).loadThumbnail(widget.node);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(explorerProvider);
    final thumb = state.thumbnails[widget.node.id];

    if (thumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          thumb,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          cacheWidth: 120,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOut,
              child: child,
            );
          },
        ),
      );
    }

    return AnimatedOpacity(
      opacity: 0.3,
      duration: const Duration(seconds: 1),
      child: const Icon(Icons.image, color: Colors.green),
    );
  }
}
