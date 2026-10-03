/// Mapper app — offline-first structure capture.
///
/// The UI never awaits the network (C4). Every action writes to the local store
/// and returns immediately; the mapper can work indefinitely with no
/// connectivity.
library;

import 'package:flutter/material.dart';

import 'core/local_store.dart';
import 'core/sync_service.dart';

void main() {
  runApp(const MapperApp());
}

class MapperApp extends StatelessWidget {
  const MapperApp({super.key, this.store});

  /// Injected by tests so the widget tree can be exercised without real file
  /// I/O. Production passes null and the screen opens the store itself.
  final LocalStore? store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mapper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF2E7D32)),
      home: CaptureScreen(initialStore: store),
    );
  }
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, this.initialStore});

  final LocalStore? initialStore;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  LocalStore? _store;
  SyncService? _sync;

  int _structures = 0;
  int _pending = 0;
  bool _online = false;
  String _lastSyncNote = 'never';
  bool _busy = false;

  StructureType _type = StructureType.standaloneDwelling;
  bool _entranceIndependent = true;
  bool _sharedWall = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  /// Boot order is load-bearing: the local DB is opened and migrated BEFORE
  /// anything can sync, so a schema mismatch can never corrupt a push.
  Future<void> _boot() async {
    final store = widget.initialStore ?? await LocalStore.open();
    if (!mounted) return;
    final sync = SyncService(store)..addListener(_onSyncChanged);
    setState(() {
      _store = store;
      _sync = sync;
    });
    await _refreshCounts();
  }

  void _onSyncChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshCounts() async {
    final s = _store;
    if (s == null) return;
    final structures = await s.countStructures();
    final pending = await s.pendingCount();
    if (mounted) {
      setState(() {
        _structures = structures;
        _pending = pending;
      });
    }
  }

  Future<void> _capture() async {
    final s = _store;
    if (s == null) return;
    setState(() => _busy = true);
    try {
      // A real build reads the device GPS here. The capture path is identical
      // either way, which is the point: the app never depends on a fix arriving
      // before the mapper can record an observation.
      await s.captureStructure(
        lat: 12.9700 + _structures * 0.0001,
        lon: 77.5900 + _structures * 0.0001,
        type: _type,
        entranceLat: 12.96995 + _structures * 0.0001,
        entranceLon: 77.58995 + _structures * 0.0001,
        entranceIndependent: _entranceIndependent,
        isSharedWall: _sharedWall,
        floorsEstimated: 2,
        materialPrimary: 'brick_plaster',
        services: [
          ServiceRecord(
            structureLocalId: '',
            serviceType: ServiceType.water,
            source: 'informal_tap',
            quality: 'fair',
            supplyFrom: '06:00',
            supplyTo: '10:00',
          ),
        ],
      );
      await _refreshCounts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Captured locally — queued for sync')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleOnline() async {
    final s = _sync;
    if (s == null) return;
    final next = !_online;
    setState(() => _online = next);
    s.onConnectivityChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mapper — offline capture'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Center(
              child: Chip(
                avatar: Icon(_online ? Icons.cloud_done : Icons.cloud_off, size: 18),
                label: Text(_online ? 'ONLINE' : 'OFFLINE'),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statRow(),
          const SizedBox(height: 16),
          _classificationCard(),
          const SizedBox(height: 16),
          _captureButton(),
          const SizedBox(height: 16),
          _syncCard(),
        ],
      ),
    );
  }

  Widget _statRow() {
    return Row(
      children: [
        Expanded(child: _stat('Structures', '$_structures')),
        const SizedBox(width: 12),
        Expanded(child: _stat('Queued', '$_pending')),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }

  /// PRD 6.1. These are OBSERVATIONS, never inferences: the system does not
  /// guess a structure type, and no model may propose one.
  Widget _classificationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Structure classification', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'A structure is a physically distinguishable residential unit that can be '
              'assigned a unique destination for mapping and emergency dispatch.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<StructureType>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
              items: [
                for (final t in StructureType.values)
                  DropdownMenuItem(value: t, child: Text(t.label)),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Entrance is independently identifiable'),
              subtitle: const Text('The 6.1 discriminator: separate destination?'),
              value: _entranceIndependent,
              onChanged: (v) => setState(() => _entranceIndependent = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Shares a wall with another structure'),
              value: _sharedWall,
              onChanged: (v) => setState(() => _sharedWall = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _captureButton() {
    return FilledButton.icon(
      onPressed: _busy ? null : _capture,
      icon: const Icon(Icons.add_location_alt),
      label: const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Text('Capture structure (works offline)'),
      ),
    );
  }

  Widget _syncCard() {
    final s = _sync;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Synchronisation', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Last: $_lastSyncNote', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              'Sync is opportunistic: it runs only when connectivity appears. '
              'Nothing here blocks capture.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _toggleOnline,
                    icon: Icon(_online ? Icons.wifi_off : Icons.wifi),
                    label: Text(_online ? 'Go offline' : 'Reconnect'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: s == null || !_online
                        ? null
                        : () async {
                            final r = await s.syncNow(force: true);
                            if (!mounted) return;
                            setState(() => _lastSyncNote = r.toString());
                            await _refreshCounts();
                          },
                    child: const Text('Sync now'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}