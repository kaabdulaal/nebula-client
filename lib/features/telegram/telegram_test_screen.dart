import 'package:flutter/material.dart';
import 'package:nebula_client/core/services/telegram_service.dart';

class TelegramTestScreen extends StatefulWidget {
  const TelegramTestScreen({super.key});

  @override
  State<TelegramTestScreen> createState() => _TelegramTestScreenState();
}

class _TelegramTestScreenState extends State<TelegramTestScreen> {
  final _service = TelegramService();
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    try {
        _service.init();
        _service.updates.listen((update) {
            final log = "UPDATE: ${update['@type']}";
            setState(() {
                _logs.add(log);
            });
        });
        
        // Request authorization state to verify connection
        Future.delayed(const Duration(milliseconds: 500), () {
            _service.send({'@type': 'getAuthorizationState'});
        });
    } catch (e) {
        setState(() {
            _logs.add("ERROR: $e");
        });
    }
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TDLib Test')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                    ElevatedButton(
                        onPressed: () => _service.send({'@type': 'getAuthorizationState'}),
                        child: const Text('Get Auth State'),
                    ),
                    ElevatedButton(
                        onPressed: () => setState(() => _logs.clear()),
                        child: const Text('Clear Logs'),
                    ),
                ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _logs.length,
              itemBuilder: (context, index) => ListTile(
                title: Text(_logs[index], style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
