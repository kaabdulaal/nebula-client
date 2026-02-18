import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nebula_client/features/auth/data/auth_repository.dart';
import 'package:nebula_client/features/auth/state/session_provider.dart';
import 'package:nebula_client/core/repositories/credentials_repository.dart';
import 'package:nebula_client/core/services/telegram_service.dart';

class MasterPassScreen extends ConsumerStatefulWidget {
  const MasterPassScreen({super.key});

  @override
  ConsumerState<MasterPassScreen> createState() => _MasterPassScreenState();
}

class _MasterPassScreenState extends ConsumerState<MasterPassScreen> {
  final _passController = TextEditingController();
  final _confirmController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _isValid = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _passController.addListener(_validateInputs);
    _confirmController.addListener(_validateInputs);
  }

  @override
  void dispose() {
    _passController.removeListener(_validateInputs);
    _confirmController.removeListener(_validateInputs);
    _passController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _validateInputs() {
    final pass = _passController.text;
    final confirm = _confirmController.text;
    final isValid = pass.length >= 8 && pass == confirm;

    if (_isValid != isValid) {
      setState(() => _isValid = isValid);
    }
  }

  Future<void> _handleSetup() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final password = _passController.text;

      // Generate a cryptographic salt (16 bytes)
      final random = Random.secure();
      final salt = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );

      final repository = AuthRepository();

      // Execute KDF in background isolate
      final masterKey = await repository.deriveSessionKey(password, salt);

      // Persist session state in RAM only
      ref.read(sessionProvider.notifier).setSession(masterKey, salt);

      if (mounted) {
        // --- Dynamic Credentials Injection Flow ---
        final credsRepo = CredentialsRepository();

        final creds = await credsRepo.getCredentials();
        if (creds != null) {
          print('[Auth] Credentials Ready. Initializing Telegram...');
          TelegramService().init(apiId: creds.apiId, apiHash: creds.apiHash);
          context.go('/home');
        } else {
          print('[Auth] No credentials found. Redirecting to Cartridge Setup.');
          context.go('/cartridge_setup');
        }
      }
    } catch (e) {
      if (mounted) {
        showModalBottomSheet(
          context: context,
          isDismissible: false,
          enableDrag: false,
          builder: (context) => Container(
            padding: const EdgeInsets.all(24),
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.gpp_bad_outlined, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Security Critical Error',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Key Derivation Function failed.\nError: $e',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Again'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                ),
              ],
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup Wizard')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_reset, size: 64, color: Colors.indigo),
                  const SizedBox(height: 24),
                  Text(
                    'Create Master Password',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Card(
                    color: Colors.amber.withValues(alpha: 0.1),
                    child: const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.orange),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'This password cannot be recovered. If you lose it, you lose your data.',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _passController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Master Password',
                      border: OutlineInputBorder(),
                      helperText: 'Minimum 8 characters',
                    ),
                    validator: (value) {
                      if (value == null || value.length < 8) {
                        return 'Password must be at least 8 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirmController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirm Password',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value != _passController.text) {
                        return 'Passwords do not match';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  FilledButton(
                    onPressed: (_isLoading || !_isValid) ? null : _handleSetup,
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Next'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
