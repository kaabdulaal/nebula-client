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
  final _manualChatIdController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  bool _useMnemonic = false;
  bool _hasCloudMetadata = false;
  bool _isCheckingMetadata = true;
  bool _showManualDiscovery = false;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    if (auth.status == AuthStateStatus.needsRestore) {
      _hasCloudMetadata = auth.hasCloudMetadata;
      _useMnemonic = !auth.hasCloudMetadata; 
      _isCheckingMetadata = false; 
      if (auth.isDiscoveryFallback) {
        _showManualDiscovery = true;
      }
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
    _manualChatIdController.dispose();
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
      final notifier = ref.read(authProvider.notifier);
      
      if (_manualChatIdController.text.isNotEmpty) {
        final manualId = int.tryParse(_manualChatIdController.text.trim());
        if (manualId == null) {
          if (mounted) setState(() => _error = 'Invalid Manual Chat ID (must be a number)');
          return;
        }
        notifier.setManualChatId(manualId);
      }

      int result;

      if (!_hasCloudMetadata || _mnemonicController.text.isNotEmpty) {
        final mnemonic = _mnemonicController.text.trim();
        final confirm = _confirmPasswordController.text;

        if (mnemonic.isEmpty && _hasCloudMetadata) {
          // User just provided password for existing vault
          debugPrint('[RestoreUI] Cloud Password Branch chosen. Calling restoreWithCloudPassword...');
          result = await ref.read(authProvider.notifier).restoreWithCloudPassword(password);
        } else {
          // Verification logic for Mnemonic
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

          debugPrint('[RestoreUI] Mnemonic Branch chosen. Calling recoverVaultWithMnemonic...');
          result = await ref.read(authProvider.notifier).recoverVaultWithMnemonic(mnemonic, password);
        }
      } else {
        debugPrint('[RestoreUI] Cloud Password Branch chosen. Calling restoreWithCloudPassword...');
        result = await ref.read(authProvider.notifier).restoreWithCloudPassword(password);
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
        title: Text(_hasCloudMetadata ? 'Unlock Existing Vault' : 'Restore Vault'),
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
                  if (_hasCloudMetadata) ...[
                    const SizedBox(height: 32),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Vault Password',
                        border: OutlineInputBorder(),
                        hintText: 'Enter password used for cloud backup',
                      ),
                      onSubmitted: (_) => _restore(),
                    ),
                    const SizedBox(height: 24),
                    Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        title: const Text('Advanced / Lost Password',
                            style: TextStyle(color: Colors.white54, fontSize: 13)),
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8.0),
                            child: Text(
                              'If you lost your password, you can recover using your 12-word seed phrase.',
                              style: TextStyle(color: Colors.grey, fontSize: 13),
                            ),
                          ),
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
                          const SizedBox(height: 16),
                          TextField(
                            controller: _confirmPasswordController,
                            obscureText: true,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'New Vault Password',
                              border: OutlineInputBorder(),
                              hintText: 'Set a new password for restoration',
                            ),
                          ),
                        ],
                      ),
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
                      'Enter your 12-word recovery phrase and set a vault password.',
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
                        labelText: 'Vault Password',
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
                  ],
                  const SizedBox(height: 16),
                  if (!_hasCloudMetadata || ref.watch(authProvider).isDiscoveryFallback)
                    Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        initiallyExpanded: _showManualDiscovery,
                        title: const Text('Advanced: Manual Discovery',
                            style: TextStyle(color: Colors.white54, fontSize: 13)),
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8.0, vertical: 8.0),
                            child: TextField(
                              controller: _manualChatIdController,
                              style:
                                  const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'Telegram Chat ID (e.g. -100...)',
                                border: OutlineInputBorder(),
                                hintText: 'Enter if auto-discovery fails',
                              ),
                            ),
                          ),
                        ],
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
