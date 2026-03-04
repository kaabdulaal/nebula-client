import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/transfer_progress.dart';
import '../../features/upload/upload_provider.dart';
import 'package:nebula_client/core/models/upload_progress.dart';
import 'event_bus.dart';

final transferServiceProvider = StateNotifierProvider<TransferNotifier, Map<String, TransferProgress>>((ref) {
  final notifier = TransferNotifier();
  
  ref.listen(activeUploadsProvider, (previous, next) {
    notifier.updateUploads(next);
  });

  return notifier;
});

class TransferNotifier extends StateNotifier<Map<String, TransferProgress>> {
  TransferNotifier() : super({}) {
    EventBus().on<FileUploadedEvent>().listen((event) {
      if (event.jobId != null) {
        final current = {...state};
        if (current.containsKey(event.jobId)) {
          print('[TransferService] FileUploadedEvent received for ${event.jobId}. Pruning.');
          current.remove(event.jobId);
          state = current;
        }
      }
    });
  }

  void updateUploads(Map<String, UploadProgress> uploads) {
    bool changed = false;
    final current = {...state};
    
    final staleIds = current.keys.where((id) => 
      current[id]?.type == TransferType.upload && !uploads.containsKey(id)
    ).toList();
    
    for (final id in staleIds) {
      current.remove(id);
      changed = true;
    }
    
    uploads.forEach((id, p) {
      final newItem = TransferProgress(
        nebulaId: id,
        name: p.name,
        progress: p.percentComplete / 100.0,
        type: TransferType.upload,
        status: p.status.toString().split('.').last,
        statusLabel: p.statusLabel,
      );
      
      if (current[id] != newItem) {
        current[id] = newItem;
        changed = true;
      }
    });

    if (changed) {
      state = current;
    }
  }

  void updateDownload(String nebulaId, String name, double progress, {String? status}) {
    final current = {...state};
    if (progress >= 1.0) {
      current.remove(nebulaId);
    } else {
      current[nebulaId] = TransferProgress(
        nebulaId: nebulaId,
        name: name,
        progress: progress,
        type: TransferType.download,
        status: status,
      );
    }
    state = current;
  }
}
