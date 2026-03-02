import 'package:flutter/material.dart';
import '../../../core/services/telegram_service.dart';

class ProxySettingsDialog extends StatefulWidget {
  const ProxySettingsDialog({super.key});

  @override
  State<ProxySettingsDialog> createState() => _ProxySettingsDialogState();
}

class _ProxySettingsDialogState extends State<ProxySettingsDialog> {
  final _serverController = TextEditingController();
  final _portController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _secretController = TextEditingController();
  
  String _proxyType = 'proxyTypeSocks5';

  @override
  void dispose() {
    _serverController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  void _onSave() {
    final server = _serverController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    
    if (server.isEmpty || port == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter valid server and port')),
      );
      return;
    }

    TelegramService().addProxy(
      server: server,
      port: port,
      type: _proxyType,
      username: _userController.text.trim(),
      password: _passController.text.trim(),
      secret: _secretController.text.trim(),
    );

    Navigator.of(context).pop();
  }

  void _onDisable() {
    TelegramService().disableProxy();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: const Text('Proxy Settings', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _proxyType,
              dropdownColor: const Color(0xFF2A2A2A),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Proxy Type'),
              items: const [
                DropdownMenuItem(value: 'proxyTypeSocks5', child: Text('SOCKS5')),
                DropdownMenuItem(value: 'proxyTypeHttp', child: Text('HTTP')),
                DropdownMenuItem(value: 'proxyTypeMtproto', child: Text('MtProto')),
              ],
              onChanged: (val) => setState(() => _proxyType = val!),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _serverController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Server Host / IP'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _portController,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            if (_proxyType != 'proxyTypeMtproto') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _userController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Username (Optional)'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passController,
                style: const TextStyle(color: Colors.white),
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password (Optional)'),
              ),
            ] else ...[
              const SizedBox(height: 16),
              TextField(
                controller: _secretController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'MtProto Secret'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _onDisable,
          child: const Text('Disable Proxy', style: TextStyle(color: Colors.redAccent)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        FilledButton(
          onPressed: _onSave,
          child: const Text('Apply Settings'),
        ),
      ],
    );
  }
}
