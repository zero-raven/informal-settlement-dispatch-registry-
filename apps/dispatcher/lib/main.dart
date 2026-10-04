/// Dispatcher app — emergency operations.
///
/// Looks up a structure code, shows the route, and records the outcome. The
/// outcome is the fast signal (PRD 6.4): a failed dispatch opens a mapper
/// re-verification task immediately.
///
/// This app never holds resident identity. Occupant context is resolved by
/// consent-api and is absent unless a resident opted in (C3, §6.3).

library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const DispatcherApp());

const Color kAmber = Color(0xFFF57C00);
const Color kRed = Color(0xFFC62828);
const Color kGreen = Color(0xFF2E7D32);

class DispatcherApp extends StatelessWidget {
  const DispatcherApp({super.key, this.baseUrl, this.role = 'dispatcher'});

  /// Injected by tests; defaults to the local registry API.
  final String? baseUrl;
  final String role;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dispatch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: kAmber,
        brightness: Brightness.dark,
      ),
      home: DispatchScreen(baseUrl: baseUrl, role: role),
    );
  }
}

class LookupResult {
  LookupResult(this.data, this.error, this.status);

  final Map<String, dynamic>? data;
  final String? error;
  final int status;

  bool get ok => error == null;
}

class DispatchScreen extends StatefulWidget {
  const DispatchScreen({super.key, this.baseUrl, this.role = 'dispatcher'});

  final String? baseUrl;
  final String role;

  @override
  State<DispatchScreen> createState() => _DispatchScreenState();
}

class _DispatchScreenState extends State<DispatchScreen> {
  final _code = TextEditingController();
  final _api = 'http://127.0.0.1:8090';
  final _graph = 'http://127.0.0.1:8092';

  LookupResult? _lookup;
  Map<String, dynamic>? _route;
  bool _busy = false;
  String? _outcomeNote;

  @override
  void initState() {
    super.initState();
    _probeBackend();
  }

  Future<Map<String, String>> _headers() async =>
      {'Content-Type': 'application/json', 'X-Role': widget.role};

  Future<void> _probeBackend() async {
    try {
      final res = await http.get(Uri.parse('${widget.baseUrl ?? _api}/v1/dispatch/capabilities'),
          headers: await _headers());
      if (res.statusCode == 200 && mounted) {
        final c = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _outcomeNote =
            'backend: ${c['backend']} · profiles: ${(c['profiles'] as List).join(', ')}');
      }
    } catch (_) {
      if (mounted) setState(() => _outcomeNote = 'registry API unreachable');
    }
  }

  Future<void> _lookupCode() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _lookup = null;
      _route = null;
    });
    try {
      final base = widget.baseUrl ?? _api;
      final res = await http.post(
        Uri.parse('$base/v1/dispatch/lookup'),
        headers: await _headers(),
        body: jsonEncode({'code': code, 'profile': 'foot'}),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() {
        _lookup = LookupResult(
          res.statusCode == 200 ? body : null,
          res.statusCode == 200 ? null : (body['error'] ?? 'lookup_failed'),
          res.statusCode,
        );
      });

      if (res.statusCode == 200) {
        await _fetchRoute(body);
      }
    } catch (e) {
      if (mounted) setState(() => _lookup = LookupResult(null, e.toString(), 0));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchRoute(Map<String, dynamic> lookup) async {
    final dest = lookup['destination'] as Map<String, dynamic>?;
    if (dest == null) return;
    try {
      final res = await http.post(
        Uri.parse('$_graph/v1/graph/route'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'from': {'lat': 12.9680, 'lon': 77.5871}, // staging point
          'to': dest,
          'profile': 'foot',
        }),
      );
      if (mounted) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _route = res.statusCode == 200 ? body : null);
      }
    } catch (_) {
      // No graph is an honest state: the destination is still known and useful.
      if (mounted) setState(() => _route = null);
    }
  }

  Future<void> _recordOutcome(String outcome) async {
    final lookup = _lookup?.data;
    if (lookup == null) return;
    try {
      final base = widget.baseUrl ?? _api;
      final assigned = await http.post(
        Uri.parse('$base/v1/dispatch/assign'),
        headers: await _headers(),
        body: jsonEncode({'code': lookup['code'], 'responder': 'unit-1'}),
      );
      final id = (jsonDecode(assigned.body) as Map)['dispatch_id'];
      await http.post(
        Uri.parse('$base/v1/dispatch/outcome'),
        headers: await _headers(),
        body: jsonEncode({
          'dispatch_id': id,
          'outcome': outcome,
          'code': lookup['code'],
          'actor': 'dispatch:unit-1',
        }),
      );
      if (mounted) {
        setState(() => _outcomeNote = outcome == 'failed'
            ? 'Recorded FAILURE — a mapper re-verification task was opened'
            : 'Recorded SUCCESS');
      }
    } catch (e) {
      if (mounted) setState(() => _outcomeNote = 'could not record outcome: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatch'),
        actions: [
          IconButton(
            tooltip: 'backend',
            onPressed: _probeBackend,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _codeField(),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _lookupCode,
            icon: const Icon(Icons.search),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Look up structure'),
            ),
          ),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (_lookup != null) _result(),
          const SizedBox(height: 24),
          if (_outcomeNote != null)
            Text(_outcomeNote!,
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _codeField() {
    return TextField(
      controller: _code,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: 'Structure code',
        hintText: 'SLR-C41001',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.qr_code),
      ),
      onSubmitted: (_) => _lookupCode(),
    );
  }

  Widget _result() {
    final l = _lookup!;
    if (!l.ok) {
      return _errorCard(l.error!, l.status);
    }
    final d = l.data!;
    final structure = (d['structure'] as Map?)?.cast<String, dynamic>() ?? {};
    final zone = (d['zone'] as Map?)?.cast<String, dynamic>() ?? {};
    final dest = (d['destination'] as Map).cast<String, dynamic>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.place, color: kRed),
                    const SizedBox(width: 8),
                    Text(d['code'] as String,
                        style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${dest['lat']}, ${dest['lon']}'),
                Text('zone: ${zone['code'] ?? '?'} · status: ${structure['status'] ?? '?'}'),
                Text('type: ${structure['structure_type'] ?? '?'}'),
                // PRD 6.3: absence is the default, not an omission.
                const Divider(height: 24),
                Row(
                  children: [
                    const Icon(Icons.person_off, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      (d['occupant_context'] as Map?)?['present'] == true
                          ? 'occupant context on file'
                          : 'no occupant context (not consented or not recorded)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _routeCard(),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _recordOutcome('confirmed'),
                icon: const Icon(Icons.check, color: kGreen),
                label: const Text('Reached'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _recordOutcome('failed'),
                icon: const Icon(Icons.report_problem, color: Colors.white),
                label: const Text('Failed'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _routeCard() {
    final r = _route;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: r == null
            ? const Text(
                'No route available. The destination is still known — send by '
                'the best available access point and report the outcome.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r['total_distance_m']} m · graph v${r['graph_version']}',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('${r['unverified_legs']} of ${(r['legs'] as List).length} legs inferred'),
                  // Inference is surfaced, never hidden (C8).
                  if ((r['warnings'] as List).isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final w in r['warnings'])
                      Text('⚠ $w',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: kAmber)),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _errorCard(String error, int status) {
    final (icon, colour, advice) = switch (error) {
      'outside_mapped_zone' => (
          Icons.block,
          kRed,
          'Dispatch is limited to the pilot mapped zone (PRD 3). Ask a mapper team to survey this zone.'
        ),
      'structure_in_dedup_review' => (
          Icons.help_outline,
          kAmber,
          'Identity is unresolved. A human must review the duplicate before anyone is sent.'
        ),
      'code_not_finalized' => (
          Icons.pause_circle_outline,
          kAmber,
          'This structure has no stable code yet.'
        ),
      'code_superseded' => (
          Icons.sync_problem,
          kAmber,
          'This placard is out of date — the structure was merged. Use the surviving code.'
        ),
      'structure_not_found' => (
          Icons.search_off,
          kRed,
          'No such code.'
        ),
      _ => (Icons.error, kRed, 'Lookup failed.'),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colour, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('HTTP $status', style: Theme.of(context).textTheme.labelMedium),
                  Text(error, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(advice, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}