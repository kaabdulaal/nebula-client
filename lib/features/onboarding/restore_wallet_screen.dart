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
  bool _useMnemonic = false;
  bool _hasCloudMetadata = false;
  bool _isCheckingMetadata = true;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    if (auth.status == AuthStateStatus.needsRestore) {
      _hasCloudMetadata = true;
      _useMnemonic = false;
      _isCheckingMetadata = false; 
    }
    _checkForMetadata();
    _listenForAuthReady();
  }

  void _listenForAuthReady() {
    ref.listenManual(authProvider, (previous, next) {
      if (next.status == AuthStateStatus.ready) {
        if (mounted && NebulaApi.instance.isInitialized) {
          debugPrint('[RestoreScreen] Auth is READY and Core is Initialized. Navigating home...');
          context.go('/home');
        }
      } else if (next.status == AuthStateStatus.vaultCorrupted && mounted) {
        setState(() => _error = next.errorMessage ?? 'Vault is corrupted. Please wipe and retry.');
        setState(() => _isLoading = false);
      }
    });
  }

  Future<void> _checkForMetadata() async {
    if (!mounted) return;
    
    if (!_hasCloudMetadata) {
      setState(() {
        _isLoading = true;
        _isCheckingMetadata = true;
      });
    }

    try {
      final anchorService = VaultAnchorService();
      final channelId = await anchorService.findNebulaChannel();
      if (channelId != null) {
        final meta = await anchorService.getCloudMetadata(channelId);
        if (meta != null && mounted) {
          setState(() {
            _hasCloudMetadata = true;
            _useMnemonic = false;
          });
          return;
        }
      }
      
      if (mounted && !_hasCloudMetadata) {
        setState(() => _useMnemonic = true);
      }
    } catch (e) {
      debugPrint('[RestoreScreen] Metadata check error: $e');
      if (mounted && !_hasCloudMetadata) setState(() => _useMnemonic = true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isCheckingMetadata = false;
        });
      }
    }
  }

  bool _guardWarningShown = false;

  @override
  void dispose() {
    _mnemonicController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final password = _passwordController.text;

    if (password.length < 8) {
      if (mounted) setState(() => _error = 'Password must be at least 8 characters');
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      int result;

      if (!_useMnemonic && _hasCloudMetadata) {
        debugPrint('[RestoreUI] Cloud Password Branch chosen. Calling restoreWithCloudPassword...');
        result = await ref.read(authProvider.notifier).restoreWithCloudPassword(password);
      } else {
        final mnemonic = _mnemonicController.text.trim();
        final confirm = _confirmPasswordController.text;

        if (mnemonic.split(' ').length != 12) {
          if (mounted) setState(() => _error = 'Please enter exactly 12 words');
          return;
        }
        if (password != confirm) {
          if (mounted) setState(() => _error = 'Passwords do not match');
          return;
        }

        if (!NebulaApi.instance.validateMnemonic(mnemonic)) {
          if (mounted) setState(() => _error = 'Invalid recovery phrase.');
          return;
        }

        if (!_guardWarningShown) {
          final guardResult = await _runRestorationGuard(mnemonic);
          if (guardResult == RestorationGuardResult.mismatch) {
            final shouldProceed = await _showGuardDialog(
              title: '⚠️ Mnemonic Mismatch',
              message: 'The recovery phrase you entered does not match the anchored backup.',
            );
            if (!shouldProceed) return;
            _guardWarningShown = true;
          }
        }

        debugPrint('[RestoreUI] Button Pressed. Calling restoreWithCloudPassword...');
        result = await ref.read(authProvider.notifier).recoverVaultWithMnemonic(mnemonic, password);
      }

        if (result == 0 && NebulaApi.instance.isInitialized) {
          if (mounted) context.go('/home');
        } else if (result != 0 && mounted) {
          final auth = ref.read(authProvider);
          final msg = auth.errorMessage ?? 'Restore failed (code: $result)';
          if (msg.contains('SUPERGROUP') || msg.contains('discovery')) {
            setState(() => _error = 'Syncing cloud data... Please try again in a moment.');
          } else {
            setState(() => _error = msg);
          }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Restore Vault'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isCheckingMetadata
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_useMnemonic && _hasCloudMetadata) ...[
                    const Text(
                      'Vault Detected in Cloud',
                      style: TextStyle(
                        color: Colors.blue,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Enter your current master password to sync and restore your data.',
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Master Password',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _restore(),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => setState(() => _useMnemonic = true),
                      child: const Text('Forgot Password? Restore with Seed Phrase'),
                    ),
                  ] else ...[
                    const Text(
                      'Manual Vault Recovery',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
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
                      onSubmitted: (_) => _restore(),
                    ),
                    if (_hasCloudMetadata)
                      TextButton(
                        onPressed: () => setState(() => _useMnemonic = false),
                        child: const Text('Back to Cloud Password'),
                      ),
                  ],
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
