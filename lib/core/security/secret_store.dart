import 'dart:convert';

/// SecretStore manages obfuscated "factory" credentials.
/// These are used as a final fallback if both the remote Gist and the
/// local database are unavailable or empty.
class SecretStore {
  // Obfuscated payload. This is a Base64(XOR(JSON, key)) string.
  // We use a placeholder for open-source builds.
  // The CI/CD or the developer can provide a real one via --dart-define.
  // The actual decryption happens in the C++ core.
  static const String factoryPayload = String.fromEnvironment(
    'NEBULA_FACTORY_CARTRIDGE',
    defaultValue: 'PLACEHOLDER',
  );
}
