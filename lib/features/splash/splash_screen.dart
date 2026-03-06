import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/initialization_provider.dart';
import '../../core/auth/auth_provider.dart';
import '../settings/dialogs/proxy_settings_dialog.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initAsync = ref.watch(initializationProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: initAsync.when(
          data: (_) => _buildLogo(),
          loading: () => _buildLoading(),
          error: (err, stack) => _buildError(context, ref, err),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.blueAccent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.token, color: Colors.white, size: 48),
        ),
        const SizedBox(height: 32),
        const CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2),
        const SizedBox(height: 16),
        const Text(
          'Starting Nebula...',
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildLoading() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.blueAccent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.token, color: Colors.white, size: 48),
        ),
        const SizedBox(height: 32),
        const CircularProgressIndicator(color: Colors.blueAccent),
        const SizedBox(height: 16),
        const Text(
          'Initializing Nebula...',
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, Object err) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Initialization Failed',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            err.toString(),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => const ProxySettingsDialog(),
                  );
                },
                icon: const Icon(Icons.settings_ethernet),
                label: const Text('Proxy'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () {
                  ref.read(authProvider.notifier).resetInitialization();
                  final _ = ref.refresh(initializationProvider);
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
