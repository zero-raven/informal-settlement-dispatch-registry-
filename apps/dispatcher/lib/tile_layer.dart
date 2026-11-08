/// Offline tile layer: pre-downloaded map tiles drawn under the vector
/// overlay. Tiles are bundled as assets (`tiles/{z}/{x}/{y}.png`, see
/// scripts/download-tiles.py) and read from the asset bundle — never from
/// the network. Missing tiles are simply skipped; the vector map remains.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Web-Mercator tile maths (pure, unit-tested).
class TileMath {
  /// Tile (x, y) at zoom [z] containing lat/lon.
  static (int, int) tileFor(double lat, double lon, int z) {
    final n = 1 << z;
    final xt = ((lon + 180) / 360 * n).floor();
    final latRad = lat * math.pi / 180;
    final yt = ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) / 2 * n).floor();
    return (xt.clamp(0, n - 1), yt.clamp(0, n - 1));
  }

  /// Global pixel coordinates (256px tiles) for lat/lon at zoom [z].
  static Offset globalPixel(double lat, double lon, int z) {
    final n = 1 << z;
    final x = (lon + 180) / 360 * n * 256;
    final latRad = lat * math.pi / 180;
    final y = (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) / 2 * n * 256;
    return Offset(x, y);
  }

  /// Zoom whose global pixel span best fits [spanM] metres into [pixels].
  static int zoomForSpan(double spanM, double pixels) {
    if (spanM <= 0 || pixels <= 0) return 14;
    // metres per tile at zoom z (equator): 40075016 / 2^z
    var z = 8;
    while (z < 19 && 40075016 / (1 << z) * 256 / pixels > spanM / pixels * 2) {
      // increase zoom while tiles are still larger than the view
      z++;
      if (40075016 / (1 << z) < spanM / 4) break;
    }
    return z.clamp(10, 18);
  }
}

/// Loads cached tiles for a viewport. Returns (tileRect, image) pairs.
Future<List<TileImage>> loadTiles({
  required double minLat,
  required double maxLat,
  required double minLon,
  required double maxLon,
  required int zoom,
  required double width,
  required double height,
  double padding = 24,
}) async {
  final (x0, y0) = TileMath.tileFor(maxLat, minLon, zoom);
  final (x1, y1) = TileMath.tileFor(minLat, maxLon, zoom);
  final scale = (width - padding * 2) /
      ((maxLon - minLon) / 360 * (1 << zoom) * 256).clamp(1, 1e9);
  final out = <TileImage>[];
  for (var x = x0; x <= x1; x++) {
    for (var y = y0; y <= y1; y++) {
      final key = 'tiles/$zoom/$x/$y.png';
      try {
        final data = await rootBundle.load(key);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        // Screen position: project the tile's top-left corner.
        final corner = _tileCornerLatLon(x, y, zoom);
        final sx = padding + (corner.$2 - minLon) / (maxLon - minLon) * (width - padding * 2);
        final sy = padding + (maxLat - corner.$1) / (maxLat - minLat) * (height - padding * 2);
        out.add(TileImage(
          Rect.fromLTWH(sx, sy, 256 * scale, 256 * scale),
          frame.image,
        ));
      } catch (_) {
        // Tile not in the pack — the vector layer underneath still shows.
      }
    }
  }
  return out;
}

(double, double) _tileCornerLatLon(int x, int y, int z) {
  final n = 1 << z;
  final lon = x / n * 360 - 180;
  final lat = math.atan(_sinh(math.pi * (1 - 2 * y / n))) * 180 / math.pi;
  return (lat, lon);
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

class TileImage {
  const TileImage(this.rect, this.image);
  final Rect rect;
  final ui.Image image;
}
