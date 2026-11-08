// Tile math for the offline pack: pure functions, no assets needed.
import 'package:flutter_test/flutter_test.dart';
import 'package:dispatcher/tile_layer.dart';

void main() {
  test('tileFor: campus centre lands in a sane tile', () {
    final (x, y) = TileMath.tileFor(12.97, 77.59, 15);
    expect(x, greaterThan(0));
    expect(y, greaterThan(0));
    expect(x, lessThan(1 << 15));
    expect(y, lessThan(1 << 15));
  });

  test('zoomForSpan returns a usable zoom for a settlement-sized span', () {
    final z = TileMath.zoomForSpan(3000, 320);
    expect(z, greaterThanOrEqualTo(10));
    expect(z, lessThanOrEqualTo(18));
  });

  test('globalPixel is monotonic in longitude', () {
    final a = TileMath.globalPixel(12.97, 77.58, 15);
    final b = TileMath.globalPixel(12.97, 77.59, 15);
    expect(b.dx, greaterThan(a.dx));
  });
}
