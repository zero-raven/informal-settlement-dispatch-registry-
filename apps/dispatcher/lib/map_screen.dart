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
import 'components.dart';

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
      final sRes = await http.get(Uri.parse('$base/v1/structures?include_deleted=false'), headers: headers)
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
              id: m['id'] as String?,
              type: m['structure_type'] as String?,
              material: m['material_primary'] as String?,
              floors: m['floors_estimated']?.toString(),
              occupancy: m['occupancy_estimate']?.toString(),
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
    final auth = context.read<AuthService>();
    final isDispatcher = auth.isDispatcher;

    return Scaffold(
      appBar: AppBar(title: const Text('Map')),
      backgroundColor: DSColors.surface0,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(DSSpacing.screenPadding),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Settlement Map',
                          style: DSTypography.displaySmall.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: DSSpacing.xs),
                      Text('Structures and recorded walks in the pilot zone',
                          style: DSTypography.bodyMedium.copyWith(color: DSColors.textSecondary)),
                    ],
                  ),
                ),
                if (isDispatcher)
                  DSSecondaryButton(
                    label: 'Refresh',
                    icon: Icons.refresh_rounded,
                    onPressed: _load,
                  ),
              ],
            ),
            const SizedBox(height: DSSpacing.lg),
            if (_error != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_off_rounded),
                  title: Text(_error!),
                  trailing: TextButton(onPressed: _load, child: const Text('Retry')),
                ),
              ),
            GestureDetector(
              onTapDown: _pins.isEmpty ? null : (details) {
                final size = MediaQuery.of(context).size;
                final cardWidth = size.width - 2 * DSSpacing.screenPadding;
                final cardHeight = 420.0;
                final proj = _getProjection(cardWidth, cardHeight);
                if (proj == null) return;
                for (final pin in _pins) {
                  final o = proj.project(pin.lat, pin.lon);
                  final dx = details.localPosition.dx - o.dx;
                  final dy = details.localPosition.dy - o.dy;
                  if (dx * dx + dy * dy <= 256) { // 16px radius
                    _showPinDetail(pin);
                    break;
                  }
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 420,
                  child: _busy && _pins.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : CustomPaint(painter: _MapPainter(pins: _pins, trail: _trail)),
                ),
              ),
            ),
            const SizedBox(height: DSSpacing.md),
            Row(
              children: [
                Expanded(child: _chip('${_pins.length} structures')),
                const SizedBox(width: DSSpacing.sm),
                Expanded(child: _chip('$_breadcrumbTotal GPS points')),
                const SizedBox(width: DSSpacing.sm),
                Expanded(child: _chip('Tap pin for details')),
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

  MapProjection? _getProjection(double width, double height) {
    final lats = [..._pins.map((p) => p.lat), ..._trail.map((p) => p.lat)];
    final lons = [..._pins.map((p) => p.lon), ..._trail.map((p) => p.lon)];
    if (lats.isEmpty) return null;
    return MapProjection.fit(lats: lats, lons: lons, width: width, height: height);
  }

  void _showPinDetail(_Pin pin) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _PinDetailSheet(
        pin: pin,
        onDelete: context.read<AuthService>().isDispatcher ? _deleteStructure : null,
        baseUrl: widget.baseUrl,
      ),
    );
  }

  Future<void> _deleteStructure(_Pin pin) async {
    if (pin.id == null) return;
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete structure?'),
        content: Text('Soft-delete ${pin.code ?? pin.id}? This marks it as deleted but keeps history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: DSColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final base = widget.baseUrl ?? 'http://127.0.0.1:8090';
      final headers = context.read<AuthService>().getAuthHeaders();
      final res = await http.delete(
        Uri.parse('$base/v1/admin/structures/${pin.id}'),
        headers: headers,
      );
      if (res.statusCode == 200) {
        await _load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted: ${pin.code ?? pin.id}'), backgroundColor: DSColors.success),
          );
        }
      } else {
        final body = jsonDecode(res.body);
        throw Exception(body['error'] ?? 'Delete failed');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: DSColors.error),
        );
      }
    }
  }

  Widget _chip(String label) {
    return Chip(label: Text(label, overflow: TextOverflow.ellipsis));
  }
}

class _Pin {
  const _Pin({
    required this.lat,
    required this.lon,
    this.code,
    this.status = '',
    this.id,
    this.type,
    this.material,
    this.floors,
    this.occupancy,
  });
  final double lat;
  final double lon;
  final String? code;
  final String status;
  final String? id;
  final String? type;
  final String? material;
  final String? floors;
  final String? occupancy;
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

class MapProjection {
  final double minLat, maxLat, minLon, maxLon, width, height;

  MapProjection._({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    required this.width,
    required this.height,
  });

  static MapProjection fit({
    required List<double> lats,
    required List<double> lons,
    required double width,
    required double height,
  }) {
    var minLat = lats.reduce(math.min);
    var maxLat = lats.reduce(math.max);
    var minLon = lons.reduce(math.min);
    var maxLon = lons.reduce(math.max);
    if (maxLat - minLat < 0.001) { minLat -= 0.0005; maxLat += 0.0005; }
    if (maxLon - minLon < 0.001) { minLon -= 0.0005; maxLon += 0.0005; }
    return MapProjection._(
      minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon,
      width: width, height: height,
    );
  }

  Offset project(double lat, double lon) => Offset(
        24 + (lon - minLon) / (maxLon - minLon) * (width - 48),
        24 + (maxLat - lat) / (maxLat - minLat) * (height - 48),
      );
}

class _PinDetailSheet extends StatelessWidget {
  final _Pin pin;
  final Future<void> Function(_Pin)? onDelete;
  final String? baseUrl;

  const _PinDetailSheet({
    required this.pin,
    this.onDelete,
    this.baseUrl,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasCode = pin.code != null && pin.code!.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: isDark ? DSColors.surface1 : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(DSBorderRadius.xl)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: DSSpacing.md),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: DSColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(DSSpacing.cardPadding),
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(DSSpacing.md),
                        decoration: BoxDecoration(
                          color: DSColors.primary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(DSBorderRadius.md),
                        ),
                        child: Icon(Icons.apartment_rounded, color: DSColors.primary, size: 28),
                      ),
                      const SizedBox(width: DSSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasCode ? pin.code! : 'Unnamed Structure',
                              style: DSTypography.headlineSmall.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              'ID: ${pin.id ?? 'Unknown'}',
                              style: DSTypography.bodySmall.copyWith(color: DSColors.textTertiary),
                            ),
                          ],
                        ),
                      ),
                      DSStatusBadge(
                        label: (pin.status.isEmpty ? 'Unknown' : pin.status).toUpperCase(),
                        type: _getStatusType(pin.status),
                      ),
                    ],
                  ),
                  const SizedBox(height: DSSpacing.lg),
                  Divider(color: DSColors.divider, height: 1),
                  const SizedBox(height: DSSpacing.lg),
                  _detailRow(Icons.category_rounded, 'Type', pin.type ?? 'Unknown'),
                  _detailRow(Icons.layers_rounded, 'Material', pin.material ?? 'Unknown'),
                  _detailRow(Icons.home_rounded, 'Floors', pin.floors ?? 'Unknown'),
                  _detailRow(Icons.people_rounded, 'Occupancy Est.', pin.occupancy ?? 'Unknown'),
                  _detailRow(Icons.location_on_rounded, 'Coordinates', '${pin.lat.toStringAsFixed(6)}, ${pin.lon.toStringAsFixed(6)}'),
                  if (onDelete != null) ...[
                    const SizedBox(height: DSSpacing.lg),
                    Divider(color: DSColors.divider, height: 1),
                    const SizedBox(height: DSSpacing.lg),
                    DSSecondaryButton(
                      label: 'Delete Structure',
                      icon: Icons.delete_rounded,
                      onPressed: () {
                        Navigator.pop(context);
                        onDelete!(pin);
                      },
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DSSpacing.lg),
              child: DSPrimaryButton(
                label: 'Close',
                icon: Icons.close_rounded,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  DSStatusType _getStatusType(String? status) {
    return switch (status?.toLowerCase()) {
      'surveyed' || 'confirmed' || 'active' => DSStatusType.success,
      'pending' || 'under_review' => DSStatusType.warning,
      'failed' || 'inactive' => DSStatusType.error,
      _ => DSStatusType.neutral,
    };
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DSSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: DSColors.textTertiary),
          const SizedBox(width: DSSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: DSTypography.labelSmall.copyWith(color: DSColors.textTertiary)),
                Text(value, style: DSTypography.bodyMedium.copyWith(fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
