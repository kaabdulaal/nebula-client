import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nebula_client/core/models/upload_progress.dart';
import 'package:nebula_client/features/upload/upload_orchestrator.dart';
import 'package:nebula_client/features/explorer/explorer_provider.dart';

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
    final orchestrator = UploadOrchestrator();
    final fileId = _orchestrators.keys.length.toString() + DateTime.now().millisecondsSinceEpoch.toString(); 
    
    final hexId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    _orchestrators[hexId] = orchestrator;

    orchestrator.progress.listen((progress) {
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
    }
  }

  Future<void> resumeUpload({
    required String fileId,
    required File sourceFile,
    required String parentId,
  }) async {
    if (_orchestrators.containsKey(fileId)) return; 

    final orchestrator = UploadOrchestrator();
    _orchestrators[fileId] = orchestrator;

    orchestrator.progress.listen((progress) {
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
    }
  }
}
