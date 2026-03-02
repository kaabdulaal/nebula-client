import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';
import '../../core/security/secret_store.dart';

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _showPasswordField = false;
  String? _errorMessage;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _attemptBiometricUnlock(auto: true);
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _attemptBiometricUnlock({bool auto = false}) async {
    // Skip biometrics on desktop platforms
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      if (auto) setState(() => _showPasswordField = true);
      return;
    }

    if (auto) {
      final biometricsEnabled = await SecretStore.isBiometricsEnabled();
      if (!biometricsEnabled) {
        setState(() => _showPasswordField = true);
        return;
      }
    }

    setState(() => _statusMessage = 'Authenticating...');

    debugPrint('[Biometrics] Button pressed.');
    final LocalAuthentication auth = LocalAuthentication();

    try {
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await auth.isDeviceSupported();
      debugPrint('[Biometrics] canAuthenticate: $canAuthenticate');

      if (!canAuthenticate) {
        if (!mounted) return;
        setState(() {
          _showPasswordField = true;
          _statusMessage = null;
        });
        if (!auto) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Biometrics not supported or not set up on this device.')),
          );
        }
        return;
      }

      // Check SecretStore BEFORE prompting the fingerprint scanner
      final password = await SecretStore.readVaultPassword();
      if (password == null || password.isEmpty) {
        debugPrint('[Biometrics] No password in SecretStore.');
        if (!mounted) return;
        setState(() {
          _showPasswordField = true;
          _statusMessage = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please login with your password once to enable biometrics.')),
        );
        return;
      }

      debugPrint('[Biometrics] Requesting OS authentication dialog...');
      final bool didAuthenticate = await auth.authenticate(
        localizedReason: 'Unlock Nebula Vault',
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );

      debugPrint('[Biometrics] Auth result: $didAuthenticate');
      
      if (!mounted) return;

      if (didAuthenticate) {
        ref.read(authProvider.notifier).unlockVault(password);
        setState(() => _statusMessage = null);
      } else {
        setState(() {
          _showPasswordField = true;
          _statusMessage = null;
        });
      }
    } catch (e) {
      debugPrint('[Biometrics] ERROR: $e');
      if (!mounted) return;
      setState(() {
        _showPasswordField = true;
        _statusMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Biometrics error: $e')),
      );
    }
  }

  void _onManualUnlock() {
    final password = _passwordController.text;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password cannot be empty.')),
      );
      return;
    }
    ref.read(authProvider.notifier).unlockVault(password);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final isLoading = authState.status == AuthStateStatus.loading;
    final errorMessage = authState.errorMessage;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Vault icon with subtle glow
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF6366F1).withValues(alpha: 0.15),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    size: 72,
                    color: Color(0xFF6366F1),
                  ),
                ),
                const SizedBox(height: 20),

              const Text(
                'Nebula Vault',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your files are encrypted and safe.',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),

              const SizedBox(height: 40),

              // Status message (biometric in progress)
              if (_statusMessage != null && !_showPasswordField) ...[
                const SizedBox(height: 16),
                const CircularProgressIndicator(color: Color(0xFF6366F1)),
                const SizedBox(height: 16),
                Text(
                  _statusMessage!,
                  style: TextStyle(color: Colors.grey[400]),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => setState(() {
                    _showPasswordField = true;
                    _statusMessage = null;
                  }),
                  child: const Text(
                    'Enter Password Manually',
                    style: TextStyle(color: Color(0xFF6366F1)),
                  ),
                ),
              ],

              // Password input
              if (_showPasswordField) ...[
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => isLoading ? null : _onManualUnlock(),
                  decoration: InputDecoration(
                    labelText: 'Master Password',
                    labelStyle: const TextStyle(color: Colors.white54),
                    border: const OutlineInputBorder(),
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF6366F1)),
                    ),
                    errorBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.redAccent),
                    ),
                    focusedErrorBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.redAccent),
                    ),
                    errorText: errorMessage,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white54,
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: isLoading ? null : _onManualUnlock,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 24, height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5,
                            ),
                          )
                        : const Text('Unlock', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
                // Biometric retry button (mobile only)
                if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) ...[
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: isLoading ? null : () => _attemptBiometricUnlock(auto: false),
                    icon: const Icon(Icons.fingerprint, color: Color(0xFF6366F1)),
                    label: const Text('Use Biometrics', style: TextStyle(color: Color(0xFF6366F1))),
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    ref.read(authProvider.notifier).triggerRecovery();
                    context.go('/restore-wallet');
                  },
                  child: Text('Restore Wallet', style: TextStyle(color: Colors.grey[600])),
                ),
                if (ref.read(authProvider).status == AuthStateStatus.vaultCorrupted) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => ref.read(authProvider.notifier).forceNewVaultSetup(),
                        child: const Text('Start Fresh', style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
}
