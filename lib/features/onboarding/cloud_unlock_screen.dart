import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';

class CloudUnlockScreen extends ConsumerStatefulWidget {
  const CloudUnlockScreen({super.key});

  @override
  ConsumerState<CloudUnlockScreen> createState() => _CloudUnlockScreenState();
}

class _CloudUnlockScreenState extends ConsumerState<CloudUnlockScreen> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _listenForAuthReady();
  }

  void _listenForAuthReady() {
    ref.listenManual(authProvider, (previous, next) {
      if (next.status == AuthStateStatus.ready) {
        if (mounted && NebulaApi.instance.isInitialized) {
          debugPrint('[CloudUnlock] Auth is READY. Navigating home...');
          context.go('/home');
        }
      }
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();

    super.dispose();
  }

  Future<void> _unlock() async {
    final password = _passwordController.text;

    if (password.length < 4) {
      if (mounted) setState(() => _error = 'Password must be at least 4 characters.');
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


      debugPrint('[CloudUnlock] Calling restoreWithCloudPassword...');
      final result = await notifier.restoreWithCloudPassword(password);

      if (result == 0 && NebulaApi.instance.isInitialized) {
        if (mounted) context.go('/home');
      } else if (result != 0 && mounted) {
        final auth = ref.read(authProvider);
        final msg = auth.errorMessage ?? 'Restore failed (code: $result)';
        setState(() => _error = msg);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.cloud_done_rounded,
                    color: Color(0xFF6366F1),
                    size: 48,
                  ),
                ),
                const SizedBox(height: 32),

                const Text(
                  'Vault Found',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 12),

                Text(
                  'An encrypted backup was found on your Telegram account.\n'
                  'Enter your vault password to restore.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 40),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _isLoading ? null : _unlock(),
                  decoration: InputDecoration(
                    labelText: 'Vault Password',
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
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white54,
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),

                if (_error != null || authState.errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error ?? authState.errorMessage ?? '',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],

                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _unlock,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Text(
                            'Restore & Unlock',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
                const SizedBox(height: 16),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () {
                        context.go('/restore-wallet');
                      },
                      child: Text(
                        'Forgot Password?',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
