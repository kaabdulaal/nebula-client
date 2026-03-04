import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

class SecurityManager extends ChangeNotifier {
  static final SecurityManager _instance = SecurityManager._internal();
  factory SecurityManager() => _instance;
  SecurityManager._internal();

  Uint8List? _vmk;
  final _keyController = StreamController<Uint8List?>.broadcast();
  Stream<Uint8List?> get onKeyChanged => _keyController.stream;
  
  Completer<Uint8List> _firstKeyCompleter = Completer<Uint8List>();
  Future<Uint8List> get vmkFuture => _vmk != null ? Future.value(_vmk!) : _firstKeyCompleter.future;

  Uint8List? get vmk => _vmk != null ? Uint8List.fromList(_vmk!) : null;

  bool get isReady => _vmk != null;

  void setMasterKey(Uint8List key) {
    _vmk = Uint8List.fromList(key);
    if (!_firstKeyCompleter.isCompleted) {
      _firstKeyCompleter.complete(_vmk);
    }
    _keyController.add(_vmk);
    debugPrint('[SECURITY] Master Key updated in SecurityManager.');
    notifyListeners();
  }

  void clearKeys() {
    _vmk = null;
    _firstKeyCompleter = Completer<Uint8List>();
    _keyController.add(null);
    notifyListeners();
  }
}
