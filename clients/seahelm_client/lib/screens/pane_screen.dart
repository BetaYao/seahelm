import 'package:flutter/material.dart';

import '../srp/models.dart';
import '../srp/srp_client.dart';

/// Read-only pane viewer (pane.read) with a send-text field.
/// Phase 2 replaces the text view with an xterm.dart terminal on pane.attach.
class PaneScreen extends StatefulWidget {
  final SrpClient client;
  final PaneInfo pane;
  const PaneScreen({super.key, required this.client, required this.pane});

  @override
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> {
  final _input = TextEditingController();
  String _content = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final text = await widget.client.paneRead(widget.pane.id);
    if (mounted) setState(() => _content = text);
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.isEmpty) return;
    _input.clear();
    await widget.client.paneSendText(widget.pane.id, '$text\n');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.pane.worktree} · ${widget.pane.id}'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF1E1E2E),
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: Text(
                  _content,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFFCDD6F4),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration:
                          const InputDecoration(hintText: 'Send to pane…'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: _send),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
