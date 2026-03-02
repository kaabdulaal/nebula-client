import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/upload_progress.dart';
import '../../core/services/sync_engine.dart';
import 'upload_orchestrator.dart';
import '../explorer/explorer_provider.dart';

final activeUploadsProvider = StateNotifierProvider<UploadNotifier, Map<String, UploadProgress>>((ref) {
  return UploadNotifier(ref);
});

class UploadNotifier extends StateNotifier<Map<String, UploadProgress>> {
  final Ref ref;
  UploadNotifier(this.ref) : super({});

  final Map<String, UploadOrchestrator> _orchestrators = {};

  Future<void> startUpload({
    required File sourceFile,
    required String parentId,
  }) async {
    final vmk = SyncEngine().isSecurityHardened ? SyncEngine().masterKeySnapshot : null;
    final orchestrator = UploadOrchestrator(vmk: vmk);
    
    final hexId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    _orchestrators[hexId] = orchestrator;

    orchestrator.progress.listen((progress) {
      if (!mounted) return;
      state = {
        ...state,
        progress.fileId: progress,
      };

      if (progress.status == UploadStatus.success) {
        ref.read(explorerProvider.notifier).refresh();
        _orchestrators.remove(progress.fileId);
      } else if (progress.status == UploadStatus.failed) {
        _orchestrators.remove(progress.fileId);
      }
    });
    
    try {
      await orchestrator.startUpload(sourceFile: sourceFile, parentId: parentId, fileId: hexId);
    } catch (e) {
      // Error handled by status stream
    }
  }

  Future<void> resumeUpload({
    required String fileId,
    required File sourceFile,
    required String parentId,
  }) async {
    if (_orchestrators.containsKey(fileId)) return; 

    final vmk = SyncEngine().isSecurityHardened ? SyncEngine().masterKeySnapshot : null;
    final orchestrator = UploadOrchestrator(vmk: vmk);
    _orchestrators[fileId] = orchestrator;

    orchestrator.progress.listen((progress) {
      if (!mounted) return;
      state = {
        ...state,
        fileId: progress,
      };

      if (progress.status == UploadStatus.success || progress.status == UploadStatus.failed) {
        _orchestrators.remove(fileId);
      }
    });

    try {
      await orchestrator.resumeUpload(fileId: fileId, sourceFile: sourceFile, parentId: parentId);
    } catch (e) {
      // Error handled by status stream
    }
  }
}
