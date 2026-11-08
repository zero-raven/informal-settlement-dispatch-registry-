// Widget smoke test. Substantive coverage lives in offline_capture_test.dart.
//
// The store is INJECTED so the widget tree renders without real file I/O.
// Opening a real SQLite file inside a testWidgets body deadlocks the fake-async
// zone, which is a test-harness constraint, not a product one.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapper/core/local_store.dart';
import 'package:mapper/main.dart';
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
    dir = Directory.systemTemp.createTempSync('mapper-widget-').path;
    PathProviderPlatform.instance = _FakePathProvider(dir);
    store = await LocalStore.open();
  });

  tearDown(() async {
    await store.close();
    if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
  });

  testWidgets('mapper app boots and shows the capture screen', (tester) async {
    // Tall viewport: the capture button sits below the classification card.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MapperApp(store: store));
    await tester.pump();
    expect(find.text('Mapper — offline capture'), findsOneWidget);
    expect(find.text('Capture structure (works offline)'), findsOneWidget);
  });

  testWidgets('capturing from the UI works with no network', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MapperApp(store: store));
    await tester.pump();

    // The capture handler awaits a real SQLite write, which lives outside the
    // fake-async zone. runAsync lets the real event loop turn over; without it
    // the await never completes and the test hangs.
    await tester.runAsync(() async {
      await tester.tap(find.text('Capture structure (works offline)'));
      // give the transaction a real chance to commit
      for (var i = 0; i < 50 && await store.countStructures() == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(await tester.runAsync(() => store.countStructures()), 1,
        reason: 'a tap must capture locally without any connectivity');
    expect(await tester.runAsync(() => store.pendingCount()), greaterThanOrEqualTo(1));
  });
}