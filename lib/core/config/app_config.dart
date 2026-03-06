enum AppFlavor {
  dev,
  prod,
}

class AppConfig {
  final String appName;
  final String apiBaseUrl;
  final AppFlavor flavor;
  final bool enableLogging;

  const AppConfig({
    required this.appName,
    required this.apiBaseUrl,
    required this.flavor,
    required this.enableLogging,
  });

  factory AppConfig.dev() => const AppConfig(
        appName: 'Nebula (Dev)',
        apiBaseUrl: 'https://dev-api.nebula.example.com',
        flavor: AppFlavor.dev,
        enableLogging: true,
      );

  factory AppConfig.prod() => const AppConfig(
        appName: 'Nebula',
        apiBaseUrl: 'https://api.nebula.example.com',
        flavor: AppFlavor.prod,
        enableLogging: false,
      );

  bool get isDev => flavor == AppFlavor.dev;
  bool get isProd => flavor == AppFlavor.prod;
}
