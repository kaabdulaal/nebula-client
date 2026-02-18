import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/nebula_api.dart';

class RestoreWalletScreen extends ConsumerStatefulWidget {
  const RestoreWalletScreen({super.key});

  @override
  ConsumerState<RestoreWalletScreen> createState() =>
      _RestoreWalletScreenState();
}

class _RestoreWalletScreenState extends ConsumerState<RestoreWalletScreen> {
  final _mnemonicController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _mnemonicController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final mnemonic = _mnemonicController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    if (mnemonic.split(' ').length != 12) {
      setState(() => _error = 'Please enter exactly 12 words');
      return;
    }

    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }

    if (password != confirm) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      print('🚀 [Recovery] Validating Mnemonic...');
      if (!NebulaApi.instance.validateMnemonic(mnemonic)) {
        setState(() => _error =
            'Invalid recovery phrase. Please check the words and order.');
        return;
      }

      print('🚀 [Recovery] Starting Native Recovery...');
      final result = await NebulaApi.instance.recoverVault(mnemonic, password);
      print('🚀 [Recovery] Native Status: $result');

      // After recovery, the DB is initialized with the Master Key.
      // We don't need to call init() again if g_initialized is true on native side.

      if (mounted) {
        context.go('/home');
      }
    } on NebulaError catch (e) {
      setState(() => _error = 'Recovery failed: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Restore Vault'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your 12-word recovery phrase and set a new master password.',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _mnemonicController,
              maxLines: 3,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Recovery Mnemonic (12 words)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _passwordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'New Master Password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPasswordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Confirm New Password',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 24),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 48),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _restore,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Restore & Unlock'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
