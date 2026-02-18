import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/api/nebula_api.dart';
import 'seed_screen.dart';

// Provider to hold the password temporarily until final DB creation
final onboardingPasswordProvider = StateProvider<String?>((ref) => null);

class SeedVerificationScreen extends ConsumerStatefulWidget {
  const SeedVerificationScreen({super.key});

  @override
  ConsumerState<SeedVerificationScreen> createState() =>
      _SeedVerificationScreenState();
}

class _SeedVerificationScreenState
    extends ConsumerState<SeedVerificationScreen> {
  late int _challengeIndex;
  final _wordController = TextEditingController();
  String? _error;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Pick a random index to challenge (0-11)
    _challengeIndex = Random().nextInt(12);
  }

  Future<void> _verifyAndComplete() async {
    final seed = ref.read(onboardingSeedProvider);
    final password = ref.read(onboardingPasswordProvider);

    if (seed == null || password == null) {
      setState(() => _error = "Session invalid. Please restart onboarding.");
      return;
    }

    final correctWord = seed[_challengeIndex];
    if (_wordController.text.trim().toLowerCase() != correctWord) {
      setState(() => _error = "Incorrect word. Please try again.");
      return;
    }

    // Verification Success! Initialize the DB.
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final docsDir = await getNebulaDocumentsDirectory();
      final dbPath = p.join(docsDir.path, 'nebula.db');

      print('🛠️ [Finalize] Creating Database with Verified Seed...');

      print('🛠️ [Finalize] Anchoring Vault with Mnemonic and Password...');

      final mnemonicString = seed.join(' ');
      final result =
          await NebulaApi.instance.setPassword(mnemonicString, password);

      if (result != 0) {
        throw Exception("Vault anchoring failed with code $result");
      }

      // Allow FS to flush
      await Future.delayed(const Duration(milliseconds: 500));

      // Clear sensitive state
      ref.invalidate(onboardingSeedProvider);
      ref.invalidate(onboardingPasswordProvider);

      if (mounted) {
        context.go('/cartridge_setup');
      }
    } catch (e) {
      setState(() => _error = "Failed to create vault: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Verify Seed'),
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const Text(
              'To ensure you backed up your recovery phrase, please confirm one word.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 32),
            Text(
              'What is word #${_challengeIndex + 1}?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _wordController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Word #${_challengeIndex + 1}',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _verifyAndComplete,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.black)
                    : const Text('Verify & Finish'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
