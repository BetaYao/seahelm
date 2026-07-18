import 'package:flutter/material.dart';

import '../srp/srp_client.dart';
import 'status_wall_screen.dart';

/// Entry screen: host + token → connect → status wall.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _host = TextEditingController(text: 'ws://192.168.1.100:7311/srp');
  final _token = TextEditingController();
  bool _connecting = false;
  String? _error;

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    final client = SrpClient(
      endpoint: Uri.parse(_host.text.trim()),
      token: _token.text.trim(),
    );
    try {
      await client.connect();
      await client.subscribe();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => StatusWallScreen(client: client)),
      );
    } catch (e) {
      await client.close();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Seahelm')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _host,
              decoration: const InputDecoration(labelText: 'SRP endpoint'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              decoration: const InputDecoration(labelText: 'Token'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            FilledButton(
              onPressed: _connecting ? null : _connect,
              child: Text(_connecting ? 'Connecting…' : 'Connect'),
            ),
          ],
        ),
      ),
    );
  }
}
