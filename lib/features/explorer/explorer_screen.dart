import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/nebula_api.dart';

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
    // Prevent accessing the DB before the build is complete or if not initialized
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadFiles();
    });
  }

  Future<void> _loadFiles() async {
    // Safety check: Don't crash if core isn't ready
    if (!NebulaApi.instance.isInitialized) {
      print('⚠️ [Explorer] Core not initialized, skipping file load.');
      return;
    }

    setState(() => _isLoading = true);
    
    try {
      // Simulate FFI call or use real one
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (mounted) {
        setState(() {
          _files = []; // Empty for now until we have real file listing
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
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('My Vault'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
               // Cleanup and logout
               NebulaApi.instance.cleanup();
               context.go('/');
            },
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            onPressed: () {
               context.push('/telegram_test');
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
                      const Icon(Icons.folder_open, size: 64, color: Colors.white24),
                      const SizedBox(height: 16),
                      const Text(
                        'Vault is empty',
                        style: TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () {
                        },
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
                      title: Text(_files[index], style: const TextStyle(color: Colors.white)),
                      leading: const Icon(Icons.insert_drive_file, color: Colors.blue),
                    );
                  },
                ),
    );
  }
}
