import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';
import '../../core/services/vault_anchor_service.dart';
import '../../core/services/telegram_service.dart';

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
  bool _guardWarningShown = false;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    _listenForAuthReady();
  }

  void _listenForAuthReady() {
    ref.listenManual(authProvider, (previous, next) {
      if (next.status == AuthStateStatus.ready) {
        if (mounted && NebulaApi.instance.isInitialized) {
          debugPrint('[RestoreScreen] Auth is READY. Navigating home...');
          context.go('/home');
        }
      } else if (next.status == AuthStateStatus.vaultCorrupted && mounted) {
        setState(() => _error = next.errorMessage ?? 'Vault is corrupted. Please wipe and retry.');
        setState(() => _isLoading = false);
      }
    });
  }

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

    if (mnemonic.isEmpty) {
      if (mounted) setState(() => _error = 'Please enter your 12-word recovery phrase.');
      return;
    }
    if (mnemonic.split(' ').length != 12) {
      if (mounted) setState(() => _error = 'Please enter exactly 12 words.');
      return;
    }
    if (password.length < 8) {
      if (mounted) setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }
    if (password != confirm) {
      if (mounted) setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (!NebulaApi.instance.validateMnemonic(mnemonic)) {
      if (mounted) setState(() => _error = 'Invalid recovery phrase.');
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final notifier = ref.read(authProvider.notifier);
      if (!_guardWarningShown) {
        final guardResult = await _runRestorationGuard(mnemonic);
        if (guardResult == RestorationGuardResult.mismatch) {
          final shouldProceed = await _showGuardDialog(
            title: '⚠️ Mnemonic Mismatch',
            message:
                'The recovery phrase you entered does not match the existing '
                'cloud anchor. Proceeding will create a divergent vault and '
                'overwrite the existing backup.\n\n'
                'Are you sure this is the correct phrase?',
          );
          if (!shouldProceed) {
            if (mounted) setState(() => _isLoading = false);
            return;
          }
          _guardWarningShown = true;
        }
      }

      debugPrint('[RestoreUI] Mnemonic Branch: Calling recoverVaultWithMnemonic...');
      final result = await notifier.recoverVaultWithMnemonic(mnemonic, password);

      if (result == 0 && NebulaApi.instance.isInitialized) {
        if (mounted) context.go('/home');
      } else if (result != 0 && mounted) {
        final auth = ref.read(authProvider);
        final msg = auth.errorMessage ?? 'Recovery failed (code: $result)';
        setState(() => _error = msg);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<RestorationGuardResult> _runRestorationGuard(String mnemonic) async {
    try {
      final tgService = TelegramService();
      final anchorService = VaultAnchorService(telegramService: tgService);

      final tgUserId = await tgService.getMe();
      return await anchorService.restorationGuard(mnemonic, tgUserId);
    } catch (e) {
      debugPrint('[RestoreGuard] Guard check failed (TDLib unavailable): $e');
      return RestorationGuardResult.error;
    }
  }
  Future<bool> _showGuardDialog(
      {required String title, required String message}) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message,
            style: const TextStyle(color: Colors.white70, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Proceed Anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _showFactoryResetDialog() async {
    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('⚠️ Factory Reset', style: TextStyle(color: Colors.red)),
        content: const Text(
          'This will PERMANENTLY DELETE your local vault (nebula.db) and all un-synced data. '
          'This action cannot be undone.\n\n'
          'Use this only if you want to start fresh and create a new vault.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('WIPE EVERYTHING'),
          ),
        ],
      ),
    );

    if (proceed == true && mounted) {
      setState(() => _isLoading = true);
      await ref.read(authProvider.notifier).destroyAccount();
      if (mounted) context.go('/onboarding');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Recover Vault'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mnemonic Recovery',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter your 12-word recovery phrase and set a new vault password.',
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
                labelText: 'New Vault Password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _confirmPasswordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Confirm Vault Password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _restore(),
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
                    : const Text('Recover & Unlock'),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: TextButton(
                onPressed: _isLoading ? null : _showFactoryResetDialog,
                child: const Text(
                  'Start Fresh / Factory Reset',
                  style: TextStyle(color: Colors.redAccent, decoration: TextDecoration.underline),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
