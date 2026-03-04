enum TransferType { upload, download }

class TransferProgress {
  final String nebulaId;
  final String name;
  final double progress; 
  final TransferType type;
  final String? status;
  final String? statusLabel;

  TransferProgress({
    required this.nebulaId,
    required this.name,
    required this.progress,
    required this.type,
    this.status,
    this.statusLabel,
  });
}
