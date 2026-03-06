import 'dart:convert';

void main(List<String> args) {
  if (args.length < 3) {
    print('Usage: dart encrypt_gist_config.dart <api_id> <api_hash> <xor_key>');
    print('Example: dart encrypt_gist_config.dart 12345 abcdef6789 xorKey123');
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
    'version': DateTime.now().millisecondsSinceEpoch, 
  };

  final jsonStr = jsonEncode(config);
  final jsonBytes = utf8.encode(jsonStr);
  final keyBytes = utf8.encode(xorKey);
  
  final encryptedBytes = List<int>.filled(jsonBytes.length, 0);
  for (var i = 0; i < jsonBytes.length; i++) {
    encryptedBytes[i] = jsonBytes[i] ^ keyBytes[i % keyBytes.length];
  }

  final result = base64Encode(encryptedBytes);
  
  print('--- NEBULA CARTRIDGE ENCRYPTOR ---');
  print('Original: $jsonStr');
  print('Payload: $result');
  print('----------------------------------');
}

