enum UploadStatus {
  idle,
  encrypting,
  uploading,
  waitingFloodWait,
  success,
  failed,
}

class UploadProgress {
  final String fileId;
  final String name;
  final double percentComplete;
  final double currentSpeed; 
  final UploadStatus status;
  final String? error;

  UploadProgress({
    required this.fileId,
    required this.name,
    required this.percentComplete,
    required this.currentSpeed,
    required this.status,
    this.error,
  });

  Map<String, dynamic> toJson() {
    return {
      'file_id': fileId,
      'name': name,
      'percent_complete': percentComplete,
      'current_speed': currentSpeed,
      'status': status.name,
      'error': error,
    };
  }
}
