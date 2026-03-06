import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/repositories/credentials_repository.dart';
import '../../core/auth/auth_provider.dart';
import '../../core/auth/auth_state.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isCustom = false;
  bool _isLoading = false;

  final _apiIdController = TextEditingController();
  final _apiHashController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pageController.dispose();
    _apiIdController.dispose();
    _apiHashController.dispose();
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final repo = CredentialsRepository();


      if (_isCustom) {
        final apiId = int.tryParse(_apiIdController.text);
        final apiHash = _apiHashController.text.trim();

        if (apiId == null || apiHash.length != 32) {
          setState(() {
            _error = "Invalid API ID or Hash (32 chars hex)";
            _isLoading = false;
          });
          return;
        }
        await repo.saveCredentials(apiId, apiHash, isCustom: true);
      } else {
        await repo.clearCustomCredentials();
      }

      if (!mounted) return;
      await ref.read(authProvider.notifier).completeOnboarding();
      
      if (!mounted) return;
      final authState = ref.read(authProvider);
      if (authState.status == AuthStateStatus.initial && authState.errorMessage != null) {
        setState(() {
          _error = authState.errorMessage;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = "Error: $e";
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _currentPage = page),
                children: [
                  _buildSlide(
                    'Welcome to Nebula',
                    'Secure, distributed cloud storage built on the Telegram Network.',
                    Icons.rocket_launch_outlined,
                  ),
                  _buildSlide(
                    'Decentralized Storage',
                    'Your files are split into encrypted chunks and stored across your personal Telegram cloud.',
                    Icons.cloud_off_outlined,
                  ),
                  _buildSlide(
                    'Ultimate Organization',
                    'Manage your digital life with a familiar folder structure, backed by a powerful local database.',
                    Icons.folder_copy_outlined,
                  ),
                  _buildSlide(
                    'No Monthly Fees',
                    'Leverage Telegram\'s infrastructure. No subscriptions, no limits, just your data.',
                    Icons.monetization_on_outlined,
                  ),
                  _buildInjectionSlide(),
                ],
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildSlide(String title, String description, IconData icon) {
    return Padding(
      padding: const EdgeInsets.all(40.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 100, color: Colors.blueAccent),
          const SizedBox(height: 40),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 20),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildInjectionSlide() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Configure Network',
            style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          const Text(
            'Load the API Cartridge to connect to the Telegram Network.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          Container(
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildToggleButton('Standard', !_isCustom),
                ),
                Expanded(
                  child: _buildToggleButton('Custom (BYOK)', _isCustom),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          if (!_isCustom) ...[
            const Icon(Icons.cloud_download, size: 48, color: Colors.blueAccent),
            const SizedBox(height: 16),
            const Text(
              'Fetch secure configuration from Nebula Repository.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
          ] else ...[
            TextField(
              controller: _apiIdController,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'API ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiHashController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'API HASH',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _loadConfiguration,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _isLoading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('Load Configuration',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleButton(String text, bool active) {
    return GestureDetector(
      onTap: () => setState(() => _isCustom = text.contains('Custom')),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? Colors.blueAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? Colors.white : Colors.white54,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: List.generate(
                5,
                (index) => Container(
                      margin: const EdgeInsets.only(right: 8),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _currentPage == index
                            ? Colors.blueAccent
                            : Colors.white24,
                      ),
                    )),
          ),
          if (_currentPage < 4)
            TextButton(
              onPressed: () {
                _pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.ease);
              },
              child: const Text(
                'NEXT',
                style: TextStyle(
                    color: Colors.blueAccent, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }
}
