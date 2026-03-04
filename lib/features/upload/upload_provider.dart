import 'dart:io';
import 'package:flutter/foundation.dart';
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
    final orchestrator = UploadOrchestrator();
    if (vmk != null) orchestrator.setMasterKey(vmk);
    
    final hexId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    _orchestrators[hexId] = orchestrator;

    orchestrator.progress.listen((progress) {
      if (!mounted) return;
      state = {
        ...state,
        progress.fileId: progress,
      };

      if (progress.status == UploadStatus.success || progress.status == UploadStatus.failed) {
        _log('UPLOAD FINALIZED: ${progress.fileId} (${progress.status}). Clearing state.');
        final newState = {...state};
        newState.remove(progress.fileId);
        state = newState;
        
        _orchestrators.remove(progress.fileId);
        if (progress.status == UploadStatus.success) {
          ref.read(explorerProvider.notifier).refresh();
        }
      }
    });
    
    try {
      await orchestrator.startUpload(sourceFile: sourceFile, parentId: parentId, fileId: hexId);
    } catch (e) {
      _log('UPLOAD INITIATION FAILED: $e');
    }
  }

  void _log(String msg) {
    if (kDebugMode) print('[UPLOAD_NOTIFIER] $msg');
  }

  Future<void> resumeUpload({
    required String fileId,
    required File sourceFile,
    required String parentId,
  }) async {
    if (_orchestrators.containsKey(fileId)) return; 

    final vmk = SyncEngine().isSecurityHardened ? SyncEngine().masterKeySnapshot : null;
    final orchestrator = UploadOrchestrator();
    if (vmk != null) orchestrator.setMasterKey(vmk);
    _orchestrators[fileId] = orchestrator;

    orchestrator.progress.listen((progress) {
      if (!mounted) return;
      state = {
        ...state,
        fileId: progress,
      };

      if (progress.status == UploadStatus.success || progress.status == UploadStatus.failed) {
        state = {...state};
        state.remove(fileId);
        _orchestrators.remove(fileId);
        if (progress.status == UploadStatus.success) {
           ref.read(explorerProvider.notifier).refresh();
        }
      }
    });

    try {
      await orchestrator.resumeUpload(fileId: fileId, sourceFile: sourceFile, parentId: parentId);
    } catch (e) {
      _log('RESUME INITIATION FAILED: $e');
    }
  }
}
