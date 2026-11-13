/// Offline vector map.
///
/// No network tiles are ever loaded: this canvas draws the settlement from
/// locally stored data — captured structures (pins), the recorded breadcrumb
/// walk (polyline), and the mapper's live position. That is the only honest
/// offline map: it shows exactly what the device knows, nothing more.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tile_layer.dart';

class MapPin {
  const MapPin({required this.lat, required this.lon, this.label, this.synced = true, this.code});
  final double lat;
  final double lon;
  final String? label;
  final bool synced;
  final String? code;
}

class MapTrailPoint {
  const MapTrailPoint({required this.lat, required this.lon});
  final double lat;
  final double lon;
}

/// Pure coordinate projection, unit-tested without pixels.
class MapProjection {
  MapProjection({
    required double initMinLat,
    required double initMaxLat,
    required double initMinLon,
    required double initMaxLon,
    required this.width,
    required this.height,
    this.padding = 24,
  })  : minLat = initMinLat,
        maxLat = initMaxLat,
        minLon = initMinLon,
        maxLon = initMaxLon;

  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;
  final double width;
  final double height;
  final double padding;

  /// Centre a data extent in the viewport with padding. North is up.
  factory MapProjection.fit({
    required List<double> lats,
    required List<double> lons,
    required double width,
    required double height,
    double padding = 36,
  }) {
    var minLat = lats.reduce(math.min); var maxLat = lats.reduce(math.max);
    var minLon = lons.reduce(math.min); var maxLon = lons.reduce(math.max);
    if (maxLat - minLat < 0.001) { minLat -= 0.0005; maxLat += 0.0005; }
    if (maxLon - minLon < 0.001) { minLon -= 0.0005; maxLon += 0.0005; }
    return MapProjection(
      initMinLat: minLat, initMaxLat: maxLat, initMinLon: minLon, initMaxLon: maxLon,
      width: width, height: height, padding: padding,
    );
  }

  Offset project(double lat, double lon) {
    final w = width - padding * 2;
    final h = height - padding * 2;
    final x = padding + (lon - minLon) / (maxLon - minLon) * w;
    final y = padding + (maxLat - lat) / (maxLat - minLat) * h;
    return Offset(x, y);
  }

  /// Approximate scale: metres per pixel at the centre latitude.
  double get metresPerPixel {
    final latSpanM = (maxLat - minLat) * 111320;
    return latSpanM / (height - padding * 2);
  }
}

class OfflineMapView extends StatefulWidget {
  const OfflineMapView({
    super.key,
    required this.pins,
    required this.trail,
    this.livePosition,
    this.height = 320,
    this.onPinTap,
  });

  final List<MapPin> pins;
  final List<MapTrailPoint> trail;
  final MapTrailPoint? livePosition;
  final double height;
  final void Function(MapPin)? onPinTap;

  @override
  State<OfflineMapView> createState() => _OfflineMapViewState();
}

class _OfflineMapViewState extends State<OfflineMapView> {
  List<TileImage>? _tiles;

  @override
  void didUpdateWidget(OfflineMapView old) {
    super.didUpdateWidget(old);
    if (old.pins != widget.pins || old.trail != widget.trail) {
      _tiles = null;
    }
  }

  Future<List<TileImage>> _loadFor(Size size) async {
    final lats = <double>[...widget.pins.map((p) => p.lat), ...widget.trail.map((p) => p.lat)];
    final lons = <double>[...widget.pins.map((p) => p.lon), ...widget.trail.map((p) => p.lon)];
    if (widget.livePosition != null) {
      lats.add(widget.livePosition!.lat);
      lons.add(widget.livePosition!.lon);
    }
    if (lats.isEmpty) return const [];
    final zoom = TileMath.zoomForSpan(
      (lats.reduce(math.max) - lats.reduce(math.min)) * 111320, size.height);
    return loadTiles(
      minLat: lats.reduce(math.min), maxLat: lats.reduce(math.max),
      minLon: lons.reduce(math.min), maxLon: lons.reduce(math.max),
      zoom: zoom, width: size.width, height: size.height,
    );
  }

  MapProjection? _getProjection(Size size) {
    final lats = <double>[...widget.pins.map((p) => p.lat), ...widget.trail.map((p) => p.lat)];
    final lons = <double>[...widget.pins.map((p) => p.lon), ...widget.trail.map((p) => p.lon)];
    if (widget.livePosition != null) { lats.add(widget.livePosition!.lat); lons.add(widget.livePosition!.lon); }
    if (lats.isEmpty) return null;
    return MapProjection.fit(lats: lats, lons: lons, width: size.width, height: size.height);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Offline settlement map: ${widget.pins.length} structures, '
          '${widget.trail.length} breadcrumb points',
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          if (_tiles == null) {
            Future.microtask(() async {
              final tiles = await _loadFor(size);
              if (mounted) setState(() => _tiles = tiles);
            });
          }
          return GestureDetector(
            onTapDown: widget.onPinTap == null ? null : (details) {
              final proj = _getProjection(size);
              if (proj == null) return;
              for (final pin in widget.pins) {
                final o = proj.project(pin.lat, pin.lon);
                final dx = details.localPosition.dx - o.dx;
                final dy = details.localPosition.dy - o.dy;
                if (dx * dx + dy * dy <= 144) { // 12px radius (pin is 9px + tap tolerance)
                  widget.onPinTap!(pin);
                  break;
                }
              }
            },
            child: CustomPaint(
              painter: _OfflineMapPainter(
                  pins: widget.pins, trail: widget.trail,
                  livePosition: widget.livePosition, tiles: _tiles ?? const []),
            ),
          );
        }),
      ),
    );
  }
}

class _OfflineMapPainter extends CustomPainter {
  _OfflineMapPainter({required this.pins, required this.trail, required this.livePosition, this.tiles = const []});
  final List<MapPin> pins;
  final List<MapTrailPoint> trail;
  final MapTrailPoint? livePosition;
  final List<TileImage> tiles;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 50 || size.height < 50) return;
    // Background: deep map surface, subtle grid streets every ~50 m.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF0B1220));

    // Pre-downloaded tiles (offline pack) under the vector overlay.
    for (final t in tiles) {
      canvas.drawImageRect(t.image, Rect.fromLTWH(0, 0, t.image.width.toDouble(), t.image.height.toDouble()), t.rect, Paint()..color = const Color(0xFFFFFFFF).withOpacity(0.85));
    }

    final lats = <double>[...pins.map((p) => p.lat), ...trail.map((p) => p.lat)];
    final lons = <double>[...pins.map((p) => p.lon), ...trail.map((p) => p.lon)];
    if (livePosition != null) { lats.add(livePosition!.lat); lons.add(livePosition!.lon); }

    if (lats.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'No mapping data yet.\nStart a walk or capture a structure.',
          style: TextStyle(color: Color(0xFF8FA3BF), fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 32);
      tp.paint(canvas, Offset(16, size.height / 2 - tp.height / 2));
      return;
    }

    final proj = MapProjection.fit(
        lats: lats, lons: lons, width: size.width, height: size.height);

    // Grid lines (~50 m spacing).
    final grid = Paint()
      ..color = const Color(0xFF1B2A44)
      ..strokeWidth = 1;
    final step = 50 / proj.metresPerPixel;
    if (step > 8) {
      for (var x = proj.padding % step; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      }
      for (var y = proj.padding % step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
    }

    // Breadcrumb trail.
    if (trail.length > 1) {
      final path = Path();
      for (var i = 0; i < trail.length; i++) {
        final o = proj.project(trail[i].lat, trail[i].lon);
        if (i == 0) { path.moveTo(o.dx, o.dy); } else { path.lineTo(o.dx, o.dy); }
      }
      canvas.drawPath(path, Paint()
        ..color = const Color(0xFF2EC4B6)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round);
    }

    // Structure pins: teal = synced, amber = queued offline.
    for (final p in pins) {
      final o = proj.project(p.lat, p.lon);
      final colour = p.synced ? const Color(0xFF2EC4B6) : const Color(0xFFFFC24B);
      canvas.drawCircle(o, 9, Paint()..color = colour.withOpacity(0.25));
      canvas.drawCircle(o, 4.5, Paint()..color = colour);
      canvas.drawCircle(o, 4.5, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }

    // Live position: pulsing-style double ring.
    if (livePosition != null) {
      final o = proj.project(livePosition!.lat, livePosition!.lon);
      canvas.drawCircle(o, 14, Paint()..color = const Color(0xFF4DA3FF).withOpacity(0.2));
      canvas.drawCircle(o, 6, Paint()..color = const Color(0xFF4DA3FF));
    }

    // North arrow + scale, top-right.
    const north = Offset(0, -10);
    final origin = Offset(size.width - 28, 30);
    final arrow = Paint()
      ..color = const Color(0xFFD6E4F5)
      ..strokeWidth = 2;
    canvas.drawLine(origin, origin + north, arrow);
    canvas.drawLine(origin + north, origin + Offset(4, -3), arrow);
    canvas.drawLine(origin + north, origin + Offset(-4, -3), arrow);
    final scaleText = TextPainter(
      text: TextSpan(
        text: '${proj.metresPerPixel.round()} m/px',
        style: const TextStyle(color: Color(0xFF8FA3BF), fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    scaleText.paint(canvas, Offset(size.width - 56, 42));
  }

  @override
  bool shouldRepaint(_OfflineMapPainter old) =>
      old.pins != pins || old.trail != trail || old.livePosition != livePosition;
}
