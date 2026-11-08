/// Mapper app — offline-first settlement mapping.
///
/// What a mapper needs, in order:
///  1. See where they are and what has been captured (offline vector map).
///  2. Walk the settlement recording GPS breadcrumbs — all local.
///  3. Capture structures against the live fix, or by manual entry.
///  4. When connectivity returns, push everything (structures + breadcrumbs)
///     to the registry, then pull server changes.
///
/// The UI never awaits the network to save anything (C4). Sync is
/// opportunistic (C5): it runs when the mapper reconnects, never in the
/// background, and a dropped connection mid-push loses nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'core/gps_service.dart';
import 'core/local_store.dart';
import 'core/sync_service.dart';
import 'map_view.dart';

const _uuid = Uuid();

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
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2EC4B6),
        scaffoldBackgroundColor: const Color(0xFF0F1115),
      ),
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
  int _breadcrumbs = 0;
  int _unsyncedBreadcrumbs = 0;
  double _walkDistanceM = 0;
  bool _online = false;
  String _lastSyncNote = 'never';
  bool _busy = false;

  StructureType _type = StructureType.standaloneDwelling;
  bool _entranceIndependent = true;
  bool _sharedWall = false;

  // --- GPS walk state ---
  bool _walking = false;
  String? _traceId;
  int _seq = 0;
  GpsFix? _liveFix;
  StreamSubscription<GpsFix>? _walkSub;

  // --- Map data (loaded from the local store only) ---
  List<MapPin> _pins = const [];
  List<MapTrailPoint> _trail = const [];

  // --- Sync configuration (persisted; previously never configurable) ---
  final _apiUrlController = TextEditingController();

  // Editable capture fields. Prefilled from the live GPS fix when available.
  final _latController = TextEditingController();
  final _lonController = TextEditingController();
  final _floorsController = TextEditingController(text: '1');
  final _materialController = TextEditingController(text: 'brick_plaster');

  @override
  void dispose() {
    _walkSub?.cancel();
    _latController.dispose();
    _lonController.dispose();
    _floorsController.dispose();
    _materialController.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

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
    // Show the UI immediately; the saved server URL applies when it loads.
    setState(() {
      _store = store;
      _sync = sync;
    });
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final savedUrl = prefs.getString('api_base_url');
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _apiUrlController.text = savedUrl;
      sync.baseUrl = savedUrl;
    }
    await _refreshCounts();
    await _refreshMap();
  }

  void _onSyncChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshCounts() async {
    final s = _store;
    if (s == null) return;
    final structures = await s.countStructures();
    final pending = await s.pendingCount();
    final crumbs = await s.breadcrumbCount();
    final unsynced = await s.unsyncedBreadcrumbCount();
    final dist = await s.walkDistanceM();
    if (mounted) {
      setState(() {
        _structures = structures;
        _pending = pending;
        _breadcrumbs = crumbs;
        _unsyncedBreadcrumbs = unsynced;
        _walkDistanceM = dist;
      });
    }
  }

  Future<void> _refreshMap() async {
    final s = _store;
    if (s == null) return;
    final rows = await s.allStructures();
    final crumbs = await s.allBreadcrumbs();
    if (mounted) {
      setState(() {
        _pins = rows.map((r) => MapPin(
              lat: (r['lat'] as num).toDouble(),
              lon: (r['lon'] as num).toDouble(),
              synced: (r['dirty'] as int?) != 1,
            )).toList();
        _trail = crumbs.map((r) => MapTrailPoint(
              lat: (r['lat'] as num).toDouble(),
              lon: (r['lon'] as num).toDouble(),
            )).toList();
      });
    }
  }

  // ------------------------------------------------------------------- GPS

  Future<void> _useCurrentLocation() async {
    final status = await ensureGpsPermission();
    if (!mounted) return;
    if (status != GpsStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status == GpsStatus.servicesOff
            ? 'Location services are off — enter coordinates manually.'
            : 'Location permission not granted — enter coordinates manually.'),
      ));
      return;
    }
    final fix = await currentFix();
    if (!mounted) return;
    if (fix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No GPS fix yet — try again outdoors.')),
      );
      return;
    }
    setState(() {
      _liveFix = fix;
      _latController.text = fix.lat.toStringAsFixed(6);
      _lonController.text = fix.lon.toStringAsFixed(6);
    });
  }

  Future<void> _toggleWalk() async {
    final s = _store;
    if (s == null) return;
    if (_walking) {
      await _walkSub?.cancel();
      if (!mounted) return;
      setState(() => _walking = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Walk stopped — $_breadcrumbs points, '
            '${_walkDistanceM.toStringAsFixed(0)} m. Stored offline.'),
      ));
      await _refreshCounts();
      await _refreshMap();
      return;
    }
    final status = await ensureGpsPermission();
    if (!mounted) return;
    if (status != GpsStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status == GpsStatus.servicesOff
            ? 'Location services are off — cannot record a walk.'
            : 'Location permission required to record breadcrumbs.'),
      ));
      return;
    }
    _traceId = _uuid.v4();
    _seq = 0;
    setState(() => _walking = true);
    _walkSub = walkFixStream().listen((fix) async {
      if (!mounted || !_walking) return;
      await s.addBreadcrumbPoint(
        traceId: _traceId!,
        seq: _seq++,
        lat: fix.lat,
        lon: fix.lon,
        accuracyM: fix.accuracyM,
        recordedAt: DateTime.now(),
      );
      if (mounted) {
        setState(() => _liveFix = fix);
        await _refreshCounts();
        await _refreshMap();
      }
    }, onError: (_) {
      if (mounted) setState(() => _walking = false);
    });
  }

  // --------------------------------------------------------------- capture

  Future<void> _capture() async {
    final s = _store;
    if (s == null) return;
    // Prefer the live GPS fix; fall back to the entered coordinates.
    final lat = _liveFix?.lat ?? double.tryParse(_latController.text.trim());
    final lon = _liveFix?.lon ?? double.tryParse(_lonController.text.trim());
    if (lat == null || lon == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid latitude and longitude, or use GPS')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await s.captureStructure(
        lat: lat,
        lon: lon,
        type: _type,
        entranceLat: lat,
        entranceLon: lon,
        entranceIndependent: _entranceIndependent,
        isSharedWall: _sharedWall,
        floorsEstimated: int.tryParse(_floorsController.text.trim()) ?? 1,
        materialPrimary: _materialController.text.trim().isEmpty
            ? 'unknown'
            : _materialController.text.trim(),
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
      await _refreshMap();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Captured locally — queued for sync')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ sync

  Future<void> _toggleOnline() async {
    final s = _sync;
    if (s == null) return;
    final next = !_online;
    setState(() => _online = next);
    s.onConnectivityChanged(next);
    await _refreshCounts();
  }

  Future<void> _saveApiUrl() async {
    final url = _apiUrlController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url);
    if (_sync != null) _sync!.baseUrl = url.isEmpty ? null : url;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(url.isEmpty ? 'Server URL cleared' : 'Server: $url')),
      );
    }
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
          _mapCard(),
          const SizedBox(height: 16),
          _statRow(),
          const SizedBox(height: 16),
          _walkCard(),
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

  Widget _mapCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.map_rounded, size: 20),
                const SizedBox(width: 8),
                Text('Settlement map (offline)',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (_liveFix != null)
                  Text(
                    '${_liveFix!.lat.toStringAsFixed(5)}, ${_liveFix!.lon.toStringAsFixed(5)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: OfflineMapView(
                pins: _pins,
                trail: _trail,
                livePosition: _liveFix == null
                    ? null
                    : MapTrailPoint(lat: _liveFix!.lat, lon: _liveFix!.lon),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_pins.length} structures · ${_trail.length} breadcrumb points · '
              '$_unsyncedBreadcrumbs awaiting sync. Teal = synced, amber = queued.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statRow() {
    return Row(
      children: [
        Expanded(child: _stat('Structures', '$_structures')),
        const SizedBox(width: 12),
        Expanded(child: _stat('GPS points', '$_breadcrumbs')),
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

  Widget _walkCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_walking ? Icons.directions_walk_rounded : Icons.route_rounded, size: 20),
                const SizedBox(width: 8),
                Text('GPS walk — breadcrumbs',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Chip(
                  avatar: Icon(_walking ? Icons.fiber_manual_record : Icons.pause_circle_outline, size: 14),
                  label: Text(_walking ? 'RECORDING' : 'IDLE'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Record the walk from road to door. Every fix is stored on this '
              'device immediately and uploaded when you reconnect — no signal needed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Walked: ${_walkDistanceM.toStringAsFixed(0)} m · '
              'Unsynced points: $_unsyncedBreadcrumbs',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _toggleWalk,
                icon: Icon(_walking ? Icons.stop_rounded : Icons.play_arrow_rounded),
                label: Text(_walking ? 'Stop walk' : 'Start walk'),
              ),
            ),
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latController,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(labelText: 'Latitude', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lonController,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(labelText: 'Longitude', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _useCurrentLocation,
                icon: const Icon(Icons.my_location_rounded),
                label: const Text('Use GPS location'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _floorsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Floors (estimated)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _materialController,
              decoration: const InputDecoration(labelText: 'Material (primary)', border: OutlineInputBorder()),
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
              'Structures and GPS breadcrumbs upload together; nothing here blocks capture.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Registry server URL',
                hintText: 'http://192.168.1.5:8090',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saveApiUrl,
                icon: const Icon(Icons.save_rounded),
                label: const Text('Save server URL'),
              ),
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
                            await _refreshMap();
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
