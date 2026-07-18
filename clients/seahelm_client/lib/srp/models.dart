/// SRP v1 data models — mirrors docs/srp-protocol.md event/method payloads.
library;

enum PaneStatus { unknown, running, waiting, done, failed }

PaneStatus paneStatusFrom(String s) => switch (s) {
      'running' => PaneStatus.running,
      'waiting' => PaneStatus.waiting,
      'done' => PaneStatus.done,
      'failed' => PaneStatus.failed,
      _ => PaneStatus.unknown,
    };

class StatusEvent {
  final String repo;
  final String worktree;
  final String pane;
  final PaneStatus status;
  final String agent;
  final int seq;

  StatusEvent.fromJson(Map<String, dynamic> j)
      : repo = j['repo'] as String? ?? '',
        worktree = j['worktree'] as String? ?? '',
        pane = j['pane'] as String? ?? '',
        status = paneStatusFrom(j['status'] as String? ?? ''),
        agent = j['agent'] as String? ?? '',
        seq = j['seq'] as int? ?? 0;
}

class SuggestEvent {
  final String suggestId;
  final String pane;
  final List<String> options;
  final int seq;

  SuggestEvent.fromJson(Map<String, dynamic> j)
      : suggestId = j['suggestId'] as String,
        pane = j['pane'] as String? ?? '',
        options = (j['options'] as List?)?.cast<String>() ?? const [],
        seq = j['seq'] as int? ?? 0;
}

class QuestionEvent {
  final String questionId;
  final String pane;
  final String prompt;
  final List<String> options;
  final int seq;

  QuestionEvent.fromJson(Map<String, dynamic> j)
      : questionId = j['questionId'] as String,
        pane = j['pane'] as String? ?? '',
        prompt = j['prompt'] as String? ?? '',
        options = (j['options'] as List?)?.cast<String>() ?? const [],
        seq = j['seq'] as int? ?? 0;
}

class NotificationEvent {
  final String level;
  final String text;
  final String pane;
  final int seq;

  NotificationEvent.fromJson(Map<String, dynamic> j)
      : level = j['level'] as String? ?? 'info',
        text = j['text'] as String? ?? '',
        pane = j['pane'] as String? ?? '',
        seq = j['seq'] as int? ?? 0;
}

/// One pane row inside a session snapshot.
class PaneInfo {
  final String id;
  final String repo;
  final String worktree;
  final PaneStatus status;
  final String agent;

  PaneInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        repo = j['repo'] as String? ?? '',
        worktree = j['worktree'] as String? ?? '',
        status = paneStatusFrom(j['status'] as String? ?? ''),
        agent = j['agent'] as String? ?? '';

  PaneInfo copyWith({PaneStatus? status, String? agent}) => PaneInfo._(
      id, repo, worktree, status ?? this.status, agent ?? this.agent);

  PaneInfo._(this.id, this.repo, this.worktree, this.status, this.agent);
}
