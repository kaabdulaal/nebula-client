import 'dart:async';
import '../models/file_node.dart';

class FileUploadedEvent {
  final FileNode node;
  final String? jobId;
  FileUploadedEvent(this.node, {this.jobId});
}

class CloudGhostDetectedEvent {
  final String nodeId;
  CloudGhostDetectedEvent(this.nodeId);
}

class EventBus {
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;
  EventBus._internal();

  final _controller = StreamController<dynamic>.broadcast();

  Stream<T> on<T>() {
    return _controller.stream.where((event) => event is T).cast<T>();
  }

  void emit(dynamic event) {
    _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}
