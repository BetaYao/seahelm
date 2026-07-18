/// SRP v1 client: JSON-RPC 2.0 over WebSocket, per docs/srp-protocol.md.
///
/// Skeleton scope: JSON encoding only (protobuf negotiation deferred),
/// initialize handshake, request/response correlation, event stream with
/// seq tracking for reconnect resume.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class SrpError implements Exception {
  final int code;
  final String message;
  SrpError(this.code, this.message);
  @override
  String toString() => 'SrpError($code): $message';
}

sealed class SrpEvent {}

class StatusChanged extends SrpEvent {
  final StatusEvent event;
  StatusChanged(this.event);
}

class SuggestReceived extends SrpEvent {
  final SuggestEvent event;
  SuggestReceived(this.event);
}

class QuestionReceived extends SrpEvent {
  final QuestionEvent event;
  QuestionReceived(this.event);
}

class NotificationReceived extends SrpEvent {
  final NotificationEvent event;
  NotificationReceived(this.event);
}

class SrpClient {
  final Uri endpoint;
  final String token;

  WebSocketChannel? _channel;
  final _events = StreamController<SrpEvent>.broadcast();
  final _pending = <int, Completer<dynamic>>{};
  int _nextId = 0;

  /// Highest event seq seen; sent as sinceSeq on reconnect.
  int lastSeq = 0;

  Map<String, dynamic> serverCapabilities = const {};

  SrpClient({required this.endpoint, required this.token});

  Stream<SrpEvent> get events => _events.stream;

  Future<void> connect() async {
    final channel = WebSocketChannel.connect(endpoint);
    _channel = channel;
    channel.stream.listen(_onMessage, onError: _events.addError,
        onDone: () {
      _failPending(SrpError(-32000, 'connection closed'));
    });

    final result = await request('initialize', {
      'protocolVersion': 1,
      'clientInfo': {'name': 'seahelm_client', 'kind': 'app'},
      'encodings': ['json'],
      'capabilities': {'subscribe': true, 'paneWrite': true, 'suggestPick': true},
      'token': token,
    });
    serverCapabilities =
        (result['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<void> subscribe({List<String>? topics, String? repo}) async {
    await request('subscribe', {
      'topics': topics ?? ['status/*', 'suggest/*', 'question/*', 'notification/*'],
      if (repo != null) 'scope': {'repo': repo},
      if (lastSeq > 0) 'sinceSeq': lastSeq,
    });
  }

  Future<Map<String, dynamic>> sessionSnapshot() async =>
      (await request('session.snapshot', {}) as Map).cast<String, dynamic>();

  Future<String> paneRead(String paneId) async {
    final r = await request('pane.read', {'pane': paneId});
    return r['text'] as String? ?? '';
  }

  Future<void> suggestPick(String suggestId, int index) =>
      request('suggest.pick', {'suggestId': suggestId, 'index': index});

  Future<void> questionAnswer(String questionId, int index) =>
      request('question.answer', {'questionId': questionId, 'index': index});

  Future<void> paneSendText(String paneId, String text) =>
      request('pane.send_text', {'pane': paneId, 'text': text});

  Future<dynamic> request(String method, Map<String, dynamic> params) {
    final channel = _channel;
    if (channel == null) throw StateError('not connected');
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    channel.sink.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return completer.future;
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = msg['id'];
    if (id != null) {
      final completer = _pending.remove(id as int);
      if (completer == null) return;
      final error = msg['error'];
      if (error != null) {
        completer.completeError(
            SrpError(error['code'] as int? ?? -1, error['message'] as String? ?? ''));
      } else {
        completer.complete(msg['result']);
      }
      return;
    }

    final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    final seq = params['seq'] as int? ?? 0;
    if (seq > lastSeq) lastSeq = seq;
    switch (msg['method']) {
      case 'event.status':
        _events.add(StatusChanged(StatusEvent.fromJson(params)));
      case 'event.suggest':
        _events.add(SuggestReceived(SuggestEvent.fromJson(params)));
      case 'event.question':
        _events.add(QuestionReceived(QuestionEvent.fromJson(params)));
      case 'event.notification':
        _events.add(NotificationReceived(NotificationEvent.fromJson(params)));
    }
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() async {
    await _channel?.sink.close();
    _channel = null;
    _failPending(SrpError(-32000, 'client closed'));
  }
}
