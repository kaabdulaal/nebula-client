import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/repositories/credentials_repository.dart';
import '../../../core/services/telegram_service.dart';

class ApiSettingsScreen extends ConsumerStatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  ConsumerState<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends ConsumerState<ApiSettingsScreen> {
  final _repo = CredentialsRepository();
  bool _isCustom = false;
  bool _isLoading = false;
  int _localVersion = 0;

  final _apiIdController = TextEditingController();
  final _apiHashController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCurrentSettings();
  }

  Future<void> _loadCurrentSettings() async {
    final isCustom = await _repo.isCustomCredentials();
    final version = await _repo.getLocalVersion();
    final manualCreds = await _repo.getManualCredentials();

    setState(() {
      _isCustom = isCustom;
      _localVersion = version;
      if (manualCreds != null) {
        _apiIdController.text = manualCreds.apiId.toString();
        _apiHashController.text = manualCreds.apiHash;
      } else {
        _apiIdController.clear();
        _apiHashController.clear();
      }
    });
  }

  Future<void> _handleSave() async {
    setState(() => _isLoading = true);

    try {
      if (_isCustom) {
        final id = int.tryParse(_apiIdController.text);
        final hash = _apiHashController.text.trim();
        if (id != null && hash.length == 32) {
          _repo.saveCredentials(id, hash, isCustom: true);
          _restartTelegram(id, hash);
        }
      } else {
        await _repo.syncCredentials(force: true);
        final creds = await _repo.getCredentials();
        if (creds != null) {
          _restartTelegram(creds.apiId, creds.apiHash);
        }
      }
      await _loadCurrentSettings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Settings saved. Telegram session restarted.')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _restartTelegram(int id, String hash) {
    TelegramService().dispose();
    TelegramService().init(apiId: id, apiHash: hash);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('API Credentials (Cartridge)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ListTile(
            title: Text('Cartridge Type'),
            subtitle: Text(
                'Switch between Standard keys and your own personal API keys.'),
          ),
          SwitchListTile(
            title: const Text('Manual Input (BYOK)'),
            subtitle: Text(_isCustom
                ? 'Using personal keys'
                : 'Using Nebula standard keys'),
            value: _isCustom,
            onChanged: (val) => setState(() => _isCustom = val),
          ),
          const Divider(),
          if (_isCustom) ...[
            TextField(
              controller: _apiIdController,
              decoration: const InputDecoration(labelText: 'API ID'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiHashController,
              decoration: const InputDecoration(labelText: 'API HASH'),
            ),
          ] else ...[
            ListTile(
              title: const Text('Config Version'),
              trailing: Text('v$_localVersion'),
            ),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _handleSave,
              icon: const Icon(Icons.sync),
              label: const Text('Force Sync from Gist'),
            ),
          ],
          const SizedBox(height: 32),
          if (_isCustom)
            FilledButton(
              onPressed: _isLoading ? null : _handleSave,
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Save & Restart'),
            ),
        ],
      ),
    );
  }
}
