import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../upload/upload_button.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';
import './explorer_provider.dart';
import '../../core/models/file_node.dart';
import '../transfers/download_orchestrator.dart';

class ExplorerScreen extends ConsumerWidget {
  const ExplorerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(explorerProvider);
    
    ref.listen(authProvider, (previous, next) {
      if (next.status == AuthStateStatus.initial) {
        print('[Explorer] Auth initial detected. Redirecting to Onboarding.');
        context.go('/onboarding');
      }
    });

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('My Vault'),
        backgroundColor: Colors.transparent,
        actions: [
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
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: () {
              context.push('/telegram_test');
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              context.push('/api_settings');
            },
          ),
        ],
      ),
      body: files.isEmpty
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
                  const SizedBox(height: 24),
                  const UploadButton(),
                ],
              ),
            )
          : ListView.builder(
              itemCount: files.length,
              itemBuilder: (context, index) {
                final node = files[index];
                return ListTile(
                  title: Text(node.name,
                      style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    '${(node.size / 1024).toStringAsFixed(1)} KB • ${node.syncStatus.name}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  leading: const Icon(Icons.insert_drive_file,
                      color: Colors.blue),
                  trailing: IconButton(
                    icon: const Icon(Icons.download, color: Colors.white70),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      messenger.showSnackBar(
                        SnackBar(content: Text('Downloading ${node.name}...')),
                      );
                      
                      try {
                        final orchestrator = DownloadOrchestrator();
                        final file = await orchestrator.startDownload(node);
                        
                        messenger.hideCurrentSnackBar();
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('Downloaded to: ${file.path}'),
                            backgroundColor: Colors.green,
                            duration: const Duration(seconds: 5),
                          ),
                        );
                      } catch (e) {
                        messenger.hideCurrentSnackBar();
                        if (e.toString().contains('USER_CANCELLED')) {
                          return;
                        }
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('Download failed: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                  onTap: () {
                  },
                );
              },
            ),
       floatingActionButton: files.isNotEmpty ? const UploadButton() : null,
    );
  }
}
