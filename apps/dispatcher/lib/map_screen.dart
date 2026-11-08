// Settlement Map — dispatcher/admin view of the mapped zone.
//
// Shows every known structure and the breadcrumb walks that built the
// path-graph, fetched from the registry when online. This is a management
// view: it answers "what do we know about this area, and how did we learn
// it?" — not a navigation surface (routes live in Lookup).
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'design_system.dart';
import 'package:provider/provider.dart';
import 'auth_service.dart';

class MapScreen extends StatefulWidget {
  final String? baseUrl;
  final String role;

  const MapScreen({super.key, this.baseUrl, this.role = 'dispatcher'});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  bool _busy = false;
  String? _error;
  List<_Pin> _pins = const [];
  List<_Pt> _trail = const [];
  int _breadcrumbTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _busy = true; _error = null; });
    try {
      final base = widget.baseUrl ?? 'http://127.0.0.1:8090';
      final headers = context.read<AuthService>().getAuthHeaders();
      final sRes = await http.get(Uri.parse('$base/v1/structures'), headers: headers)
          .timeout(const Duration(seconds: 8));
      final bRes = await http.get(Uri.parse('$base/v1/breadcrumbs'), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (sRes.statusCode != 200) throw 'structures HTTP ${sRes.statusCode}';
      final structures = (jsonDecode(sRes.body) as Map)['structures'] as List? ?? [];
      final points = bRes.statusCode == 200
          ? (jsonDecode(bRes.body) as Map)['points'] as List? ?? []
          : <dynamic>[];
      if (mounted) {
        setState(() {
          _pins = structures.map((e) {
            final m = e as Map<String, dynamic>;
            return _Pin(
              lat: (m['lat'] as num).toDouble(),
              lon: (m['lon'] as num).toDouble(),
              code: m['code'] as String?,
              status: m['status'] as String? ?? '',
            );
          }).toList();
          _trail = points.map((e) {
            final m = e as Map<String, dynamic>;
            return _Pt((m['lat'] as num).toDouble(), (m['lon'] as num).toDouble());
          }).toList();
          _breadcrumbTotal = _trail.length;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load map data: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Map')),
      backgroundColor: DSColors.surface0,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(DSSpacing.screenPadding),
          children: [
            Text('Settlement Map',
                style: DSTypography.displaySmall.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: DSSpacing.xs),
            Text('Structures and recorded walks in the pilot zone',
                style: DSTypography.bodyMedium.copyWith(color: DSColors.textSecondary)),
            const SizedBox(height: DSSpacing.lg),
            if (_error != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_off_rounded),
                  title: Text(_error!),
                  trailing: TextButton(onPressed: _load, child: const Text('Retry')),
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 420,
                child: _busy && _pins.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : CustomPaint(painter: _MapPainter(pins: _pins, trail: _trail)),
              ),
            ),
            const SizedBox(height: DSSpacing.md),
            Row(
              children: [
                Expanded(child: _chip('${_pins.length} structures')),
                const SizedBox(width: DSSpacing.sm),
                Expanded(child: _chip('$_breadcrumbTotal GPS points')),
                const SizedBox(width: DSSpacing.sm),
                Expanded(child: _chip('Pull to refresh')),
              ],
            ),
            const SizedBox(height: DSSpacing.lg),
            Text('Legend', style: DSTypography.titleMedium),
            const SizedBox(height: DSSpacing.sm),
            const Text('Teal line — breadcrumb walk (path-graph evidence, inference until verified). '
                'Dots — structures; labelled by code where issued. '
                'Walks are recorded offline by mappers and appear here after sync.',
                style: TextStyle(color: DSColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return Chip(label: Text(label, overflow: TextOverflow.ellipsis));
  }
}

class _Pin {
  const _Pin({required this.lat, required this.lon, this.code, this.status = ''});
  final double lat; final double lon; final String? code; final String status;
}

class _Pt {
  const _Pt(this.lat, this.lon);
  final double lat; final double lon;
}

class _MapPainter extends CustomPainter {
  _MapPainter({required this.pins, required this.trail});
  final List<_Pin> pins;
  final List<_Pt> trail;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 50 || size.height < 50) return;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF0B1220));
    final lats = [...pins.map((p) => p.lat), ...trail.map((p) => p.lat)];
    final lons = [...pins.map((p) => p.lon), ...trail.map((p) => p.lon)];
    if (lats.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'No structures mapped yet.',
          style: TextStyle(color: Color(0xFF8FA3BF), fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 32);
      tp.paint(canvas, Offset(16, size.height / 2 - 10));
      return;
    }
    var minLat = lats.reduce(math.min); var maxLat = lats.reduce(math.max);
    var minLon = lons.reduce(math.min); var maxLon = lons.reduce(math.max);
    if (maxLat - minLat < 0.001) { minLat -= 0.0005; maxLat += 0.0005; }
    if (maxLon - minLon < 0.001) { minLon -= 0.0005; maxLon += 0.0005; }
    Offset proj(double lat, double lon) => Offset(
          24 + (lon - minLon) / (maxLon - minLon) * (size.width - 48),
          24 + (maxLat - lat) / (maxLat - minLat) * (size.height - 48),
        );

    if (trail.length > 1) {
      final path = Path();
      for (var i = 0; i < trail.length; i++) {
        final o = proj(trail[i].lat, trail[i].lon);
        if (i == 0) { path.moveTo(o.dx, o.dy); } else { path.lineTo(o.dx, o.dy); }
      }
      canvas.drawPath(path, Paint()
        ..color = const Color(0xFF2EC4B6)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke);
    }
    for (final p in pins) {
      final o = proj(p.lat, p.lon);
      canvas.drawCircle(o, 8, Paint()..color = const Color(0xFF2EC4B6).withOpacity(0.25));
      canvas.drawCircle(o, 4, Paint()..color = const Color(0xFF2EC4B6));
      if (p.code != null) {
        final tp = TextPainter(
          text: TextSpan(text: p.code!, style: const TextStyle(color: Color(0xFFD6E4F5), fontSize: 9)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 120);
        tp.paint(canvas, o + const Offset(8, -6));
      }
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.pins != pins || old.trail != trail;
}
