import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nebula_client/core/auth/auth_provider.dart';

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

      ref.read(authProvider.notifier).setTempPassword(password);

      if (mounted) {
        context.push('/seed_intro');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'An unexpected error occurred: $e';
        });
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
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => ref.read(authProvider.notifier).forceRestoreState(),
                    child: const Text(
                      'I already have a Vault (Force Sync)',
                      style: TextStyle(color: Colors.white54),
                    ),
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
