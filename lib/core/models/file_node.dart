import 'dart:convert';
import 'package:nebula_client/core/services/telegram_service.dart';

enum FileNodeType { file, folder }

enum SyncStatus { uploading, synced, failed }

extension SyncStatusX on SyncStatus {
  String get label {
    switch (this) {
      case SyncStatus.uploading: return 'Uploading';
      case SyncStatus.synced: return 'Synced';
      case SyncStatus.failed: return 'Failed';
    }
  }
}

class FileNode {
  final String id;
  final String parentId;
  final FileNodeType type;
  final SyncStatus syncStatus;
  final String name;
  final int size;
  final String mimeType;
  final int? manifestMsgId;
  final DateTime createdAt;
  final DateTime modifiedAt;

  FileNode({
    required this.id,
    required this.parentId,
    required this.type,
    required this.syncStatus,
    required this.name,
    required this.size,
    required this.mimeType,
    this.manifestMsgId,
    required this.createdAt,
    required this.modifiedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'parent_id': parentId,
      'type': type.toString().split('.').last,
      'sync_status': syncStatus.toString().split('.').last,
      'name': name,
      'size': size,
      'mime_type': mimeType,
      'manifest_msg_id': manifestMsgId,
      'created_at': createdAt.toIso8601String(),
      'modified_at': modifiedAt.toIso8601String(),
    };
  }

  factory FileNode.fromJson(Map<String, dynamic> json) {
    return FileNode(
      id: json['id'] as String,
      parentId: json['parent_id'] as String,
      type: (json['type'] as String) == 'folder' ? FileNodeType.folder : FileNodeType.file,
      syncStatus: json.containsKey('sync_status') 
          ? SyncStatus.values.byName(json['sync_status'] as String)
          : SyncStatus.synced,
      name: json['name'] as String,
      size: json['size'] as int,
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      manifestMsgId: json['manifest_msg_id'] as int?,
      createdAt: json.containsKey('created_at') 
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      modifiedAt: json.containsKey('modified_at') 
          ? DateTime.parse(json['modified_at'] as String)
          : DateTime.now(),
    );
  }

  factory FileNode.fromSqlJson(Map<String, dynamic> json) {
    final modifiedAtInt = json['modified_at'];
    final modifiedAt = (modifiedAtInt != null && modifiedAtInt is int)
        ? DateTime.fromMillisecondsSinceEpoch(modifiedAtInt * 1000)
        : DateTime.fromMillisecondsSinceEpoch(TelegramService.instance.serverTime * 1000);

    return FileNode(
      id: json['id'] as String,
      parentId: json['parent_id'] as String? ?? (json['folder_id'] as String? ?? 'root'),
      type: (json['type'] as String) == 'folder' ? FileNodeType.folder : FileNodeType.file,
      syncStatus: (json['is_local'] == true) ? SyncStatus.uploading : SyncStatus.synced,
      name: json['name'] as String,
      size: json['size'] as int? ?? 0,
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      manifestMsgId: json['manifest_msg_id'] as int?,
      createdAt: modifiedAt, 
      modifiedAt: modifiedAt,
    );
  }

  @override
  String toString() => jsonEncode(toJson());

  String get extension {
    final lastDot = name.lastIndexOf('.');
    if (lastDot == -1 || lastDot == name.length - 1) return '';
    return name.substring(lastDot + 1).toLowerCase();
  }

  bool get isImage {
    if (mimeType.startsWith('image/')) return true;
    const imgExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
    return imgExts.contains(extension);
  }

  bool get isVideo {
    if (mimeType.startsWith('video/')) return true;
    const vidExts = {'mp4', 'mkv', 'avi', 'mov', 'webm'};
    return vidExts.contains(extension);
  }

  bool get isAudio {
    if (mimeType.startsWith('audio/')) return true;
    const audioExts = {'mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'};
    return audioExts.contains(extension);
  }

  bool get isPdf {
    if (mimeType == 'application/pdf') return true;
    return extension == 'pdf';
  }

  bool get isArchive {
    if (mimeType.contains('zip') || mimeType.contains('tar') || mimeType.contains('rar')) return true;
    const archiveExts = {'zip', 'tar', 'gz', 'rar', '7z'};
    return archiveExts.contains(extension);
  }
}
