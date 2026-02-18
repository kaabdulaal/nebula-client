import 'dart:convert';

void main(List<String> args) {
  if (args.length < 3) {
    print('Usage: dart encrypt_gist_config.dart <api_id> <api_hash> <xor_key>');
    print('Example: dart encrypt_gist_config.dart 12345 abcdef6789 nebula_cartridge_2026');
    return;
  }

  final apiId = int.tryParse(args[0]);
  final apiHash = args[1];
  final xorKey = args[2];

  if (apiId == null) {
    print('Invalid API ID');
    return;
  }

  final config = {
    'api_id': apiId,
    'api_hash': apiHash,
    'version': DateTime.now().millisecondsSinceEpoch, // Use timestamp as version
  };

  final jsonStr = jsonEncode(config);
  final obfuscated = xorEncrypt(jsonStr, xorKey);
  final result = base64Encode(utf8.encode(obfuscated));
  
  print('--- NEBULA CARTRIDGE ENCRYPTOR ---');
  print('Original: $jsonStr');
  print('Payload: $result');
  print('----------------------------------');
}

String xorEncrypt(String input, String key) {
  final output = StringBuffer();
  for (int i = 0; i < input.length; i++) {
    // Note: C++ uses char which is signed in some platforms or unsigned in others.
    // Dart's codeUnitAt is 16-bit. We need to ensure we treat it as 8-bit.
    final charCode = input.codeUnitAt(i) & 0xFF;
    final keyCode = key.codeUnitAt(i % key.length) & 0xFF;
    output.writeCharCode(charCode ^ keyCode);
  }
  return output.toString();
}
