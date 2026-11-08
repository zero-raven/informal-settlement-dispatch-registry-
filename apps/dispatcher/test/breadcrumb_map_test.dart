// Breadcrumb storage + offline map projection: pure/local, no GPS hardware.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dispatcher/core/local_store.dart';
import 'package:dispatcher/map_view.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dir;
  late LocalStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mapper-crumbs-').path;
    PathProviderPlatform.instance = _FakePathProvider(dir);
    store = await LocalStore.open();
  });

  tearDown(() async {
    await store.close();
    if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
  });

  test('breadcrumb points persist locally and queue for sync', () async {
    await store.addBreadcrumbPoint(
        traceId: 't1', seq: 0, lat: 12.97, lon: 77.59,
        accuracyM: 4, recordedAt: DateTime.utc(2026, 11, 8, 4));
    await store.addBreadcrumbPoint(
        traceId: 't1', seq: 1, lat: 12.9701, lon: 77.5901,
        accuracyM: 5, recordedAt: DateTime.utc(2026, 11, 8, 4, 0, 5));
    // Duplicate seq is ignored, not duplicated.
    await store.addBreadcrumbPoint(
        traceId: 't1', seq: 1, lat: 12.9701, lon: 77.5901,
        recordedAt: DateTime.utc(2026, 11, 8, 4, 0, 5));

    expect(await store.breadcrumbCount(), 2);
    expect(await store.unsyncedBreadcrumbCount(), 2);
    expect(await store.pendingCount(), 3, // 2 stored points + dup queued op is deduped server-side; local queue holds attempts
        reason: 'each add queues an outbox op');
    expect(await store.walkDistanceM(), greaterThan(10));
    expect(await store.walkDistanceM(), lessThan(30));
  });

  test('map projection: north is up, centre projects to centre', () {
    final p = MapProjection.fit(
        lats: [12.96, 12.98], lons: [77.58, 77.60], width: 400, height: 300);
    final centre = p.project(12.97, 77.59);
    expect(centre.dx, closeTo(200, 1));
    expect(centre.dy, closeTo(150, 1));
    final north = p.project(12.98, 77.59);
    expect(north.dy, lessThan(centre.dy), reason: 'higher latitude must be higher on screen');
    expect(p.metresPerPixel, greaterThan(0));
  });
}
