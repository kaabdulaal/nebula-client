import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/repositories/credentials_repository.dart';
import '../../core/services/telegram_service.dart';
import '../../core/api/nebula_api.dart';
import '../../core/auth/auth_provider.dart';

class CartridgeSetupScreen extends ConsumerStatefulWidget {
  const CartridgeSetupScreen({super.key});

  @override
  ConsumerState<CartridgeSetupScreen> createState() =>
      _CartridgeSetupScreenState();
}

class _CartridgeSetupScreenState extends ConsumerState<CartridgeSetupScreen> {
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

  Future<void> _startNebula() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final repo = CredentialsRepository();
      TelegramCredentials? creds;

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
        repo.saveCredentials(apiId, apiHash, isCustom: true);
        creds = TelegramCredentials(apiId: apiId, apiHash: apiHash);
      } else {
        final success = await repo.syncCredentials();
        if (success) {
          creds = await repo.getCredentials();
        } else {
          creds = await repo.getCredentials();
        }
      }

      if (creds != null) {
        debugPrint('[CartridgeSetup] Injecting credentials: ${creds.apiId}');
        final docsDir = await getNebulaDocumentsDirectory();
        final dbPath = p.join(docsDir.path, 'nebula_tdlib');
        await TelegramService().init(apiId: creds.apiId, apiHash: creds.apiHash, dbPath: dbPath);

        if (mounted) {
          context.go('/auth');
        }
      } else {
        setState(() {
          _error = "Failed to obtain credentials. Try manual input.";
          _isLoading = false;
          _isCustom = true; 
          _pageController.animateToPage(4,
              duration: const Duration(milliseconds: 300), curve: Curves.ease);
        });
      }
    } catch (e) {
      setState(() {
        _error = "Error: $e";
        _isLoading = false;
      });
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
                    'Decentralized Storage',
                    'Your files are split into encrypted chunks and stored across your personal Telegram cloud.',
                    Icons.cloud_off_outlined,
                  ),
                  _buildSlide(
                    'Ultimate Organization',
                    'Manage your digital life with a familiar folder structure, backed by a powerful database.',
                    Icons.folder_copy_outlined,
                  ),
                  _buildSlide(
                    'Seamless Streaming',
                    'Stream your media directly from Telegram without downloading the full file first.',
                    Icons.play_circle_outline,
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
            'Connect Nebula',
            style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          const Text(
            'The "Cartridge System" allows you to inject your own API keys for total privacy and ban immunity.',
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
            const Icon(Icons.auto_awesome, size: 48, color: Colors.blueAccent),
            const SizedBox(height: 16),
            const Text(
              'Uses secure, remote-fetched keys.\nRecommended for most users.',
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
              onPressed: _isLoading ? null : _startNebula,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _isLoading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('Start Nebula',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => ref.read(authProvider.notifier).forceRestoreState(),
            child: const Text(
              'I already have a Vault (Force Sync)',
              style: TextStyle(color: Colors.white54),
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
              onPressed: () => _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.ease),
              child: const Text('NEXT',
                  style: TextStyle(
                      color: Colors.blueAccent, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }
}
