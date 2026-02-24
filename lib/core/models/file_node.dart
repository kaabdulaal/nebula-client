import 'dart:convert';

enum FileNodeType { file, folder }

enum SyncStatus { uploading, synced, failed }

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
      'type': type.name,
      'sync_status': syncStatus.name,
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
      type: FileNodeType.values.byName(json['type'] as String),
      syncStatus: SyncStatus.values.byName(json['sync_status'] as String),
      name: json['name'] as String,
      size: json['size'] as int,
      mimeType: json['mime_type'] as String,
      manifestMsgId: json['manifest_msg_id'] as int?,
      createdAt: DateTime.parse(json['created_at'] as String),
      modifiedAt: DateTime.parse(json['modified_at'] as String),
    );
  }

  @override
  String toString() => jsonEncode(toJson());
}
