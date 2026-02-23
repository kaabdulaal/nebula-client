import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';

class ExplorerScreen extends ConsumerStatefulWidget {
  const ExplorerScreen({super.key});

  @override
  ConsumerState<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends ConsumerState<ExplorerScreen> {
  bool _isLoading = false;
  List<String> _files = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadFiles();
    });
  }

  Future<void> _loadFiles() async {
    if (!NebulaApi.instance.isInitialized) {
      print('⚠️ [Explorer] Core not initialized, skipping file load.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted) {
        setState(() {
          _files = []; 
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ [Explorer] Failed to load files: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading files: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
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
                      ElevatedButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Upload File'),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Upload File'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      title: Text(_files[index],
                          style: const TextStyle(color: Colors.white)),
                      leading: const Icon(Icons.insert_drive_file,
                          color: Colors.blue),
                    );
                  },
                ),
    );
  }
}
