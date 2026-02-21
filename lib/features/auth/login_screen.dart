import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/api/nebula_api.dart';
import '../../core/repositories/credentials_repository.dart';
import '../../core/services/telegram_service.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/auth_state.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final password = _passwordController.text;
    if (password.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await ref.read(authProvider.notifier).unlockVault(password);
      
      final auth = ref.read(authProvider);
      if (auth.status != AuthStateStatus.ready && mounted) {
        if (auth.errorMessage != null) {
          final msg = auth.errorMessage!;
          if (msg.contains('SUPERGROUP') || msg.contains('discovery')) {
            return;
          }
          setState(() => _error = msg);
        }
      }
    } catch (e) {
      setState(() => _error = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final isCorrupted = auth.status == AuthStateStatus.vaultCorrupted;
    
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isCorrupted) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        'Vault Corrupted',
                        style: TextStyle(color: Colors.red, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        auth.errorMessage ?? 'The local database is unreadable.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
                              onPressed: () {
                                ref.read(authProvider.notifier).triggerRecovery();
                                context.push('/restore-wallet');
                              },
                              child: const Text('Wipe & Restore'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                              onPressed: () {
                                ref.read(authProvider.notifier).forceNewVaultSetup();
                              },
                              child: const Text('Start Fresh'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ] else ...[
              const Icon(Icons.lock_open, size: 64, color: Colors.blue),
              const SizedBox(height: 32),
              Text(
                'Unlock Vault',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Master Password',
                  prefixIcon: const Icon(Icons.vpn_key),
                  border: const OutlineInputBorder(),
                  errorText: _error,
                ),
                onSubmitted: (_) => _login(),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  child: _isLoading
                      ? const CircularProgressIndicator()
                      : const Text('Unlock'),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  print('[Login] Recovery requested. Wiping local vault (preserving Telegram)...');
                  ref.read(authProvider.notifier).triggerRecovery();
                  context.push('/restore-wallet');
                },
                child: const Text('Forgot Password? Recovery with Mnemonic'),
              ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
