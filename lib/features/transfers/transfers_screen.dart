import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key});

  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen> {
  double _progress = 0.0;
  bool _uploading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
      ),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_upload,
                  size: 80, color: Color(0xFF6366F1)),
              const SizedBox(height: 24),
              if (_uploading) ...[
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      fontSize: 48, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 16),
                const Text('Encrypting and uploading chunks...'),
              ] else ...[
                const Text(
                  'Upload File',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _startUpload,
                  icon: const Icon(Icons.upload),
                  label: const Text('Select File'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startUpload() async {
    setState(() => _uploading = true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Upload feature pending real implementation')),
      );
      setState(() {
        _uploading = false;
        _progress = 0.0;
      });
    }
  }
}
