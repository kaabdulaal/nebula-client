import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';
import 'upload_provider.dart';

class UploadButton extends ConsumerWidget {
  final String? parentId;

  const UploadButton({
    super.key,
    this.parentId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final isUnlocked = authState.status == AuthStateStatus.ready;

    return ElevatedButton.icon(
      onPressed: isUnlocked
          ? () async {
              try {
                final result = await FilePicker.platform.pickFiles();
                if (result != null && result.files.single.path != null) {
                  final file = File(result.files.single.path!);
                  await ref.read(activeUploadsProvider.notifier).startUpload(
                        sourceFile: file,
                        parentId: parentId ?? 'root',
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
                    SnackBar(content: Text('File picker error: $e')),
                  );
                }
              }
            }
          : null,
      icon: const Icon(Icons.upload_file),
      label: const Text('Upload File'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.white10,
        disabledForegroundColor: Colors.white24,
      ),
    );
  }
}
