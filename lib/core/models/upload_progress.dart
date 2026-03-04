enum UploadStatus {
  idle,
  encrypting,
  uploading,
  waitingFloodWait,
  success,
  failed,
}

extension UploadStatusX on UploadStatus {
  String get label {
    switch (this) {
      case UploadStatus.idle: return 'Idle';
      case UploadStatus.encrypting: return 'Encrypting...';
      case UploadStatus.uploading: return 'Uploading Chunks...';
      case UploadStatus.waitingFloodWait: return 'Rate Limited (Waiting)';
      case UploadStatus.success: return 'Success';
      case UploadStatus.failed: return 'Failed';
    }
  }

  bool get isTerminal => this == UploadStatus.success || this == UploadStatus.failed;
}

class UploadProgress {
  final String fileId;
  final String name;
  final double percentComplete;
  final double currentSpeed; 
  final UploadStatus status;
  final String? statusLabel;
  final String? error;

  UploadProgress({
    required this.fileId,
    required this.name,
    required this.percentComplete,
    required this.currentSpeed,
    required this.status,
    this.statusLabel,
    this.error,
  });

  Map<String, dynamic> toJson() {
    return {
      'file_id': fileId,
      'name': name,
      'percent_complete': percentComplete,
      'current_speed': currentSpeed,
      'status': status.toString().split('.').last,
      'status_label': statusLabel,
      'error': error,
    };
  }
}
