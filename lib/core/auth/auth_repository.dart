import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import '../api/nebula_api.dart';
import '../services/telegram_service.dart';

class AuthRepository {
  final TelegramService _telegramService;

  AuthRepository({TelegramService? telegramService})
      : _telegramService = telegramService ?? TelegramService();

  Stream<Map<String, dynamic>> get updates => _telegramService.updates;

  Map<String, dynamic>? get currentAuthState =>
      _telegramService.currentAuthState;

  Future<void> initTelegram(int apiId, String apiHash, String dbPath) async {
    await _telegramService.init(apiId: apiId, apiHash: apiHash, dbPath: dbPath);
  }

  void sendPhoneNumber(String phone) {
    _telegramService.sendPhoneNumber(phone);
  }

  void checkCode(String code) {
    _telegramService.checkCode(code);
  }

  void checkPassword(String password) {
    _telegramService.checkPassword(password);
  }

  void logOut() {
    _telegramService.logOut();
  }

  void resendAuthenticationCode() {
    _telegramService.resendAuthenticationCode();
  }

  void requestAuthState() {
    _telegramService.requestAuthState();
  }

  void send(Map<String, dynamic> request) {
    _telegramService.send(request);
  }

  void dispose() {
    _telegramService.dispose();
  }

  void requestQrCodeAuthentication() {
    _telegramService.requestQrCodeAuthentication();
  }

  Future<int> getMe() => _telegramService.getMe();

  Future<Uint8List> deriveMasterKey(String mnemonic) async {
    return await compute(_kdfTask, mnemonic);
  }

  static Uint8List _kdfTask(String mnemonic) {
    final api = NebulaApi();
    final keyPtr = calloc<ffi.Uint8>(65);

    try {
      final result = api.deriveMasterKey(
        mnemonic,
        keyPtr.cast<ffi.Char>(),
        65,
      );

      if (result != 0) {
        throw Exception('KDF derivation failed (code: $result)');
      }

      final hexString = keyPtr.cast<Utf8>().toDartString();
      if (hexString.length < 64) {
        throw Exception('KDF output truncated: ${hexString.length} chars');
      }
      final validHex = hexString.substring(0, 64);
      final resultKey = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        resultKey[i] =
            int.parse(validHex.substring(i * 2, i * 2 + 2), radix: 16);
      }

      return resultKey;
    } finally {
      for (int i = 0; i < 65; i++) {
        keyPtr[i] = 0;
      }
      calloc.free(keyPtr);
    }
  }
}
