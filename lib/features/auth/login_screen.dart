import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/api/nebula_api.dart';
import '../../core/repositories/credentials_repository.dart';
import '../../core/services/telegram_service.dart';

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
      final docsDir = await getNebulaDocumentsDirectory();
      final dbPath = p.join(docsDir.path, 'nebula.db');

      print('🔓 Attempting login at: $dbPath');

      final result = await NebulaApi.instance.unlockWithPassword(password);

      if (result != 0) {
        throw NebulaError(result, 'Unlock failed');
      }

      if (mounted) {
        final credsRepo = CredentialsRepository();

        // --- Dynamic Credentials Check ---
        if (!await credsRepo.hasCredentials()) {
          print('[Login] No credentials found. Auto-syncing from Gist...');
          await credsRepo.syncCredentials();
        }

        final creds = await credsRepo.getCredentials();
        if (creds != null) {
          print('[Login] Credentials Ready. Initializing Telegram...');
          TelegramService().init(apiId: creds.apiId, apiHash: creds.apiHash);
          context.go('/home');
        } else {
          print('[Login] Credentials missing. Redirecting to Cartridge Setup.');
          context.go('/cartridge_setup');
        }
      }
    } on NebulaError catch (e) {
      if (e.code == 26 || e.code == 11) {
        // SQLITE_NOTADB or SQLITE_PROTOCOL (sometimes returned by SQLCipher on wrong key)
        setState(() => _error = 'Wrong password. Please try again.');
      } else {
        setState(() => _error = 'Error: ${e.message}');
      }
    } catch (e) {
      setState(() => _error = 'Invalid password or database error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
                onPressed: () => context.push('/restore-wallet'),
                child: const Text('Forgot Password? Recovery with Mnemonic'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
