import 'dart:convert';

class SecretStore {
  static const String factoryPayload = String.fromEnvironment(
    'NEBULA_FACTORY_CARTRIDGE',
    defaultValue: 'PLACEHOLDER',
  );
}
