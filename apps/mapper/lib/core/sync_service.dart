/// Opportunistic sync for the mapper app (C5).
///
/// Triggered when connectivity appears — never a background daemon, never a
/// long-lived socket, never a retry loop that assumes a network exists. Pulling
/// the plug mid-push is a normal state, not an error.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'local_store.dart';

class SyncOutcome {
  SyncOutcome({
    required this.attempted,
    required this.pushed,
    required this.acked,
    required this.dedupRequired,
    required this.rejected,
    this.error,
  });

  final bool attempted;
  final int pushed;
  final int acked;

  /// Ops the server refused to auto-merge; a human must review these (C2).
  final int dedupRequired;
  final int rejected;
  final String? error;

  @override
  String toString() => attempted
      ? 'pushed=$pushed acked=$acked dedup=$dedupRequired rejected=$rejected'
      : 'skipped${error == null ? '' : ' ($error)'}';
}

class SyncService extends ChangeNotifier {
  SyncService(this.store);

  final LocalStore store;

  /// null in offline-first builds; set once the API URL is configured.
  String? baseUrl;
  String? accessToken;

  bool _online = false;
  bool _busy = false;
  DateTime? _lastSync;

  /// Debounce so a flapping connection does not hammer the server.
  static const _minInterval = Duration(seconds: 30);

  bool get isOnline => _online;
  bool get isBusy => _busy;
  DateTime? get lastSync => _lastSync;

  /// Called by the connectivity listener. This is the ONLY trigger.
  void onConnectivityChanged(bool online) {
    _online = online;
    notifyListeners();
    if (online) unawaited(syncNow());
  }

  Future<SyncOutcome> syncNow({bool force = false}) async {
    if (_busy) {
      return SyncOutcome(attempted: false, pushed: 0, acked: 0, dedupRequired: 0, rejected: 0,
          error: 'already running');
    }
    if (!_online) {
      return SyncOutcome(attempted: false, pushed: 0, acked: 0, dedupRequired: 0, rejected: 0,
          error: 'offline');
    }
    final last = _lastSync;
    if (!force && last != null && DateTime.now().difference(last) < _minInterval) {
      return SyncOutcome(attempted: false, pushed: 0, acked: 0, dedupRequired: 0, rejected: 0,
          error: 'debounced');
    }

    _busy = true;
    notifyListeners();
    try {
      final batch = await store.pendingOps(limit: 50);
      if (batch.isEmpty) {
        await _pull();
        _lastSync = DateTime.now();
        return SyncOutcome(attempted: true, pushed: 0, acked: 0, dedupRequired: 0, rejected: 0);
      }

      final pushed = batch.map((r) => {
            'clientOpId': r['op_id'],
            'clientSeq': r['seq'],
            'table': r['table_name'],
            'entityId': r['entity_id'],
            'op': r['op'],
            'payload': jsonDecode(r['payload'] as String),
          }).toList();

      final res = await _post('/v1/sync/push', {'device_id': store.siteId, 'ops': pushed});
      final results = (res['results'] as List).cast<Map<String, Object?>>();

      final acked = <String>[];
      var dedup = 0;
      var rejected = 0;
      for (final r in results) {
        final id = r['clientOpId'] as String;
        switch (r['state']) {
          case 'applied':
          case 'replayed':
          case 'dedup_required':
            // dedup_required is acknowledged so it is not resent forever, but it
            // stays visible to the mapper: a human still has to decide.
            acked.add(id);
            if (r['state'] == 'dedup_required') dedup++;
          case 'rejected':
            rejected++;
            await store.recordFailure(id, (r['reason'] ?? 'rejected') as String);
          default:
            rejected++;
        }
      }
      await store.acknowledge(acked);
      await _pull();
      _lastSync = DateTime.now();
      return SyncOutcome(
        attempted: true,
        pushed: pushed.length,
        acked: acked.length,
        dedupRequired: dedup,
        rejected: rejected,
      );
    } catch (e) {
      // Network failure is an expected offline state, not an exception to raise.
      return SyncOutcome(attempted: true, pushed: 0, acked: 0, dedupRequired: 0, rejected: 0,
          error: e.toString());
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _pull() async {
    final c = await store.cursor();
    final uri = Uri.parse('$baseUrl/v1/sync/pull?zone=C4')
        .replace(queryParameters: {if (c != null) 'since': c, 'limit': '1000'});
    final res = await _get(uri.toString());
    final changes = (res['changes'] as List?)?.cast<Map<String, Object?>>() ?? [];
    for (final ch in changes) {
      final table = ch['table'];
      final id = ch['entity_id'];
      if (table == 'local_structure' && id != null) {
        // Only clear the dirty flag when the server has accepted the version.
        final payload = (ch['payload'] as Map?)?.cast<String, Object?>() ?? {};
        await _applyServerStructure(id as String, payload, (ch['version'] as int?) ?? 0);
      }
    }
    await store.setCursor(res['cursor'] as String?);
  }

  Future<void> _applyServerStructure(
      String localId, Map<String, Object?> payload, int version) async {
    // Deliberately minimal: the full pull mapping belongs in M2, which owns the
    // registry API. M1 proves the loop closes without touching the network when
    // there is no server.
  }

  Future<Map<String, Object?>> _post(String path, Map<String, Object?> body) async {
    final res = await _client
        .post(Uri.parse('$baseUrl$path'),
            headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return _decode(res);
  }

  Future<Map<String, Object?>> _get(String url) async {
    final res = await _client
        .get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 15));
    return _decode(res);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Map<String, Object?> _decode(http.Response res) {
    if (res.statusCode >= 400) {
      throw 'HTTP ${res.statusCode}: ${res.body}';
    }
    return (jsonDecode(res.body) as Map).cast<String, Object?>();
  }

  final http.Client _client = http.Client();
}
