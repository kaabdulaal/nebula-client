import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/providers/initialization_provider.dart';
import '../../core/api/nebula_api.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initAsync = ref.watch(initializationProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: Center(
        child: initAsync.when(
          data: (status) {
            Future.microtask(() async {
              if (context.mounted) {
                try {
                  switch (status) {
                    case InitializationStatus.needsOnboarding:
                      context.go('/welcome');
                      break;
                    case InitializationStatus.needsAuth:
                      context.go('/login');
                      break;
                    default:
                      context.go('/welcome');
                  }
                } catch (e) {
                  context.go('/welcome');
                }
              }
            });
            return const CircularProgressIndicator();
          },
          error: (err, stack) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                'Initialization Failed',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Text(
                  err.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => ref.refresh(initializationProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
          loading: () => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.token, color: Colors.white, size: 48),
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(color: Colors.blue),
              const SizedBox(height: 16),
              const Text(
                'Initializing Nebula...',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
