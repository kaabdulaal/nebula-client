enum TransferType { upload, download }

class TransferProgress {
  final String nebulaId;
  final String name;
  final double progress; // 0.0 to 1.0
  final TransferType type;
  final String? status;

  TransferProgress({
    required this.nebulaId,
    required this.name,
    required this.progress,
    required this.type,
    this.status,
  });
}
