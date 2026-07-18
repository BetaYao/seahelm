import 'dart:async';

import 'package:flutter/material.dart';

import '../srp/models.dart';
import '../srp/srp_client.dart';
import 'pane_screen.dart';

/// Live wall of panes grouped by repo/worktree, with inline suggest and
/// question action buttons — the mobile core loop.
class StatusWallScreen extends StatefulWidget {
  final SrpClient client;
  const StatusWallScreen({super.key, required this.client});

  @override
  State<StatusWallScreen> createState() => _StatusWallScreenState();
}

class _StatusWallScreenState extends State<StatusWallScreen> {
  final Map<String, PaneInfo> _panes = {};
  final Map<String, SuggestEvent> _suggests = {}; // keyed by pane
  final Map<String, QuestionEvent> _questions = {};
  StreamSubscription<SrpEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.client.events.listen(_onEvent);
    _loadSnapshot();
  }

  Future<void> _loadSnapshot() async {
    final snapshot = await widget.client.sessionSnapshot();
    final panes = (snapshot['panes'] as List?) ?? const [];
    setState(() {
      _panes.clear();
      for (final p in panes) {
        final info = PaneInfo.fromJson((p as Map).cast<String, dynamic>());
        _panes[info.id] = info;
      }
    });
  }

  void _onEvent(SrpEvent e) {
    setState(() {
      switch (e) {
        case StatusChanged(:final event):
          final existing = _panes[event.pane];
          if (existing != null) {
            _panes[event.pane] =
                existing.copyWith(status: event.status, agent: event.agent);
          }
        case SuggestReceived(:final event):
          _suggests[event.pane] = event;
        case QuestionReceived(:final event):
          _questions[event.pane] = event;
        case NotificationReceived(:final event):
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(event.text)));
      }
    });
  }

  Color _statusColor(PaneStatus s) => switch (s) {
        PaneStatus.running => Colors.blue,
        PaneStatus.waiting => Colors.orange,
        PaneStatus.done => Colors.green,
        PaneStatus.failed => Colors.red,
        PaneStatus.unknown => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    final byRepo = <String, List<PaneInfo>>{};
    for (final p in _panes.values) {
      byRepo.putIfAbsent(p.repo, () => []).add(p);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Panes'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadSnapshot),
        ],
      ),
      body: ListView(
        children: [
          for (final entry in byRepo.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(entry.key,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final pane in entry.value) _paneTile(pane),
          ],
          if (_panes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('No panes')),
            ),
        ],
      ),
    );
  }

  Widget _paneTile(PaneInfo pane) {
    final suggest = _suggests[pane.id];
    final question = _questions[pane.id];
    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.circle, size: 12, color: _statusColor(pane.status)),
          title: Text('${pane.worktree} · ${pane.id}'),
          subtitle: Text(pane.agent.isEmpty
              ? pane.status.name
              : '${pane.agent} · ${pane.status.name}'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PaneScreen(client: widget.client, pane: pane))),
        ),
        if (question != null)
          _actionRow(question.prompt, question.options, (i) async {
            await widget.client.questionAnswer(question.questionId, i);
            setState(() => _questions.remove(pane.id));
          }),
        if (suggest != null)
          _actionRow(null, suggest.options, (i) async {
            await widget.client.suggestPick(suggest.suggestId, i);
            setState(() => _suggests.remove(pane.id));
          }),
      ],
    );
  }

  Widget _actionRow(
      String? prompt, List<String> options, Future<void> Function(int) onPick) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (prompt != null) Text(prompt),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < options.length; i++)
                OutlinedButton(
                  onPressed: () => onPick(i),
                  child: Text(options[i]),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.client.close();
    super.dispose();
  }
}
