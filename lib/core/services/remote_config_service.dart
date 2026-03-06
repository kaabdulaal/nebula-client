import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:nebula_core/nebula_core.dart';

class RemoteConfigService {
  final _ffi = NebulaFFI();

  Future<String?> fetchRawPayload() async {
    try {
      final url = _ffi.getRemoteConfigUrl();
      if (url.isEmpty) {
        debugPrint('[RemoteConfig] FFI returned empty URL (DB likely not initialized).');
        return null;
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          return data['payload'] as String? ?? response.body.trim();
        } catch (_) {
          return response.body.trim();
        }
      }
      debugPrint('[RemoteConfig] HTTP ${response.statusCode} from URL.');
      return null;
    } catch (e) {
      debugPrint('[RemoteConfig] Error: $e');
      return null;
    }
  }
}
