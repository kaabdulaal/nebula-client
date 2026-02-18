import 'dart:convert';
import 'package:http/http.dart' as http;
import '../security/secret_store.dart';

import 'package:nebula_core/nebula_core.dart';

class RemoteConfigService {
  final _ffi = NebulaFFI();

  Future<String?> fetchRawPayload() async {
    try {
      final url = _ffi.getRemoteConfigUrl();
      if (url.isEmpty) return null;

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        // Handle both raw string and JSON-wrapped payload
        try {
          final data = jsonDecode(response.body);
          return data['payload'] as String? ?? response.body.trim();
        } catch (_) {
          return response.body.trim();
        }
      }
      return null;
    } catch (e) {
      print('[RemoteConfig] Error: $e');
      return null;
    }
  }
}
