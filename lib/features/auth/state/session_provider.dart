import 'dart:typed_data';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'session_provider.g.dart';

class SessionState {
  final Uint8List? masterKey;
  final Uint8List? salt;

  SessionState({this.masterKey, this.salt});

  bool get isAuthenticated => masterKey != null;

  SessionState copyWith({
    Uint8List? masterKey,
    Uint8List? salt,
  }) {
    return SessionState(
      masterKey: masterKey ?? this.masterKey,
      salt: salt ?? this.salt,
    );
  }
}

@Riverpod(keepAlive: true)
class Session extends _$Session {
  @override
  SessionState build() {
    // Initial state is empty, RAM-only.
    return SessionState();
  }

  void setSession(Uint8List masterKey, Uint8List salt) {
    state = SessionState(masterKey: masterKey, salt: salt);
  }

  void clearSession() {
    // Security: Explicitly zero out the key buffer if possible before dropping reference
    if (state.masterKey != null) {
      state.masterKey!.fillRange(0, state.masterKey!.length, 0);
    }
    state = SessionState();
  }
}
