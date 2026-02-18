import 'dart:async'; // Import for TimeoutException
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import '../../core/api/nebula_api.dart';

// Temporary provider to hold the generated seed during onboarding
final onboardingSeedProvider = StateProvider<List<String>?>((ref) => null);

class SeedScreen extends ConsumerStatefulWidget {
  const SeedScreen({super.key});

  @override
  ConsumerState<SeedScreen> createState() => _SeedScreenState();
}

class _SeedScreenState extends ConsumerState<SeedScreen> {
  @override
  void initState() {
    super.initState();
    // Generate seed if not already present
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(onboardingSeedProvider) == null) {
        _generateNativeSeed();
      }
    });
  }

  Future<void> _generateNativeSeed() async {
    try {
      // Add timeout to prevent infinite loading if FFI hangs
      final mnemonicString = await Future.microtask(() {
        return NebulaApi.instance.generateMnemonic();
      }).timeout(const Duration(seconds: 5), onTimeout: () {
        throw TimeoutException('Core took too long to generate seed');
      });

      final list =
          mnemonicString.split(' ').where((w) => w.isNotEmpty).toList();

      if (mounted) {
        ref.read(onboardingSeedProvider.notifier).state = list;
      }
    } catch (e) {
      if (mounted) {
        // Show error and maybe a retry button logic could be added here
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to generate seed: $e'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _generateNativeSeed,
            ),
          ),
        );
      }
    }
  }

  void _copyToClipboard(List<String> seed) {
    Clipboard.setData(ClipboardData(text: seed.join(' ')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Seed phrase copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seed = ref.watch(onboardingSeedProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Recovery Phrase'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: seed == null
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Generating secure seed...',
                        style: TextStyle(color: Colors.white54)),
                  ],
                ),
              )
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(24.0),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        const Center(
                            child: Icon(Icons.security,
                                size: 64, color: Colors.amber)),
                        const SizedBox(height: 24),
                        const Text(
                          'Write down these 12 words.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'If you lose your password, this phrase is the ONLY way to recover your vault.',
                          style: TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                      ]),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 2.5,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${index + 1}. ',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12),
                                  ),
                                  Text(
                                    seed[index],
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                        childCount: seed.length,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.all(24.0),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        const SizedBox(height: 16),
                        TextButton.icon(
                          onPressed: () => _copyToClipboard(seed),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy to Clipboard (Unsafe)'),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            onPressed: () => context.push('/seed_verify'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber,
                              foregroundColor: Colors.black,
                            ),
                            child: const Text('I have written it down'),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
