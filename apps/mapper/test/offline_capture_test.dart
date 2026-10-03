// M1 acceptance test in the actual app layer.
//
// Proves the shipped LocalStore — not a stand-in — captures structures with no
// network, survives being reopened, and keeps queued work intact.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapper/core/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

  late String tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mapper-test-').path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });

  tearDown(() {
    if (Directory(tempDir).existsSync()) {
      Directory(tempDir).deleteSync(recursive: true);
    }
  });

  test('capture works with no network and queues for sync', () async {
    final store = await LocalStore.open();
    // NOTE: no HTTP client is constructed, no baseUrl is set. If this test
    // passes, capture genuinely does not depend on connectivity.

    final id = await store.captureStructure(
      lat: 12.9700,
      lon: 77.5900,
      type: StructureType.sharedWallDwelling,
      entranceLat: 12.9699,
      entranceLon: 77.5899,
      entranceIndependent: true,
      isSharedWall: true,
      floorsEstimated: 2,
      services: [
        ServiceRecord(
          structureLocalId: '',
          serviceType: ServiceType.water,
          source: 'informal_tap',
          quality: 'fair',
        ),
      ],
    );

    expect(id, isNotEmpty);
    expect(await store.countStructures(), 1);
    // one op for the structure + one for the service record
    expect(await store.pendingCount(), 2);

    final ops = await store.pendingOps();
    // monotonic seq preserved, so replay order is deterministic
    expect(ops.map((o) => o['seq']).toList(), [1, 2]);
    await store.close();
  });

  test('30 structures captured offline survive reopening the app', () async {
    var store = await LocalStore.open();
    for (var i = 0; i < 30; i++) {
      await store.captureStructure(
        lat: 12.97 + i * 0.0001,
        lon: 77.59 + i * 0.0001,
        type: StructureType.standaloneDwelling,
        entranceIndependent: true,
      );
    }
    expect(await store.countStructures(), 30);
    expect(await store.pendingCount(), 30);
    await store.close();

    // simulate the app being killed and relaunched
    store = await LocalStore.open();
    expect(await store.countStructures(), 30, reason: 'structures survive restart');
    expect(await store.pendingCount(), 30, reason: 'outbox survives restart');

    // and a single sync clears everything exactly once
    final ops = await store.pendingOps(limit: 100);
    expect(ops.length, 30);
    await store.acknowledge(ops.map((o) => o['op_id'] as String));
    expect(await store.pendingCount(), 0);
    await store.close();
  });

  test('acknowledging part of a batch leaves the rest queued', () async {
    final store = await LocalStore.open();
    for (var i = 0; i < 5; i++) {
      await store.captureStructure(
        lat: 12.97 + i * 0.0001,
        lon: 77.59,
        type: StructureType.standaloneDwelling,
      );
    }
    final ops = await store.pendingOps();
    // the server accepted only the first two
    await store.acknowledge([ops[0]['op_id'] as String, ops[1]['op_id'] as String]);
    expect(await store.pendingCount(), 3,
        reason: 'unacknowledged work must not be dropped');
    await store.close();
  });

  test('PRD 6.6 — captured service data defaults to aggregate_only', () async {
    final store = await LocalStore.open();
    await store.captureStructure(
      lat: 12.97,
      lon: 77.59,
      type: StructureType.standaloneDwelling,
    );
    final rows = await store.allStructures();
    expect(rows.first['disclosure_policy'], 'aggregate_only');
    expect(rows.first['code'], isNull,
        reason: 'a code is issued only after a human dedup decision');
    await store.close();
  });

  test('PRD 6.1 classification round-trips through the local store', () async {
    final store = await LocalStore.open();
    for (final t in StructureType.values) {
      await store.captureStructure(
        lat: 12.97,
        lon: 77.59,
        type: t,
      );
    }
    final rows = await store.allStructures();
    final stored = rows.map((r) => r['structure_type']).toSet();
    expect(stored.length, StructureType.values.length,
        reason: 'every 6.1 type must be storable');
    await store.close();
  });
}