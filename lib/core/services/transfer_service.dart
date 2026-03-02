import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/transfer_progress.dart';
import '../../features/upload/upload_provider.dart';

final transferServiceProvider = StateNotifierProvider<TransferNotifier, Map<String, TransferProgress>>((ref) {
  final notifier = TransferNotifier();
  
  // Listen to uploads
  ref.listen(activeUploadsProvider, (previous, next) {
    notifier.updateUploads(next);
  });

  return notifier;
});

class TransferNotifier extends StateNotifier<Map<String, TransferProgress>> {
  TransferNotifier() : super({});

  void updateUploads(Map<String, dynamic> uploads) {
    final current = {...state};
    // Remove uploads not in the map
    current.removeWhere((id, p) => p.type == TransferType.upload && !uploads.containsKey(id));
    
    // Add/Update uploads
    uploads.forEach((id, p) {
      current[id] = TransferProgress(
        nebulaId: id,
        name: p.name,
        progress: p.percentComplete / 100.0,
        type: TransferType.upload,
        status: p.status.name,
      );
    });
    state = current;
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
