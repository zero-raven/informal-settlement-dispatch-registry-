/// Local offline store for the mapper app.
///
/// Every read in this app comes from here. The UI never awaits the network
/// (C4): a capture writes here and enqueues an outbox row, and that is the
/// whole of what "saving" means from the mapper's point of view.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// PRD 6.1 — a structure is a physically distinguishable residential unit
/// that can be assigned a unique destination. These values encode the
/// classification rules; the mapper selects one by OBSERVATION.
enum StructureType {
  standaloneDwelling,
  sharedWallDwelling,
  multiHouseholdSingleEntry,
  compoundDwelling,
  temporaryShelter,
  nonResidential;

  String get wire => switch (this) {
        StructureType.standaloneDwelling => 'standalone_dwelling',
        StructureType.sharedWallDwelling => 'shared_wall_dwelling',
        StructureType.multiHouseholdSingleEntry => 'multi_household_single_entry',
        StructureType.compoundDwelling => 'compound_dwelling',
        StructureType.temporaryShelter => 'temporary_shelter',
        StructureType.nonResidential => 'non_residential',
      };

  static StructureType fromWire(String s) => StructureType.values.firstWhere(
        (e) => e.wire == s,
        orElse: () => StructureType.standaloneDwelling,
      );

  String get label => switch (this) {
        StructureType.standaloneDwelling => 'Standalone dwelling',
        StructureType.sharedWallDwelling => 'Shared wall, separate entrance',
        StructureType.multiHouseholdSingleEntry => 'One building, one entrance',
        StructureType.compoundDwelling => 'Dwelling in a compound',
        StructureType.temporaryShelter => 'Temporary shelter',
        StructureType.nonResidential => 'Non-residential (for navigation)',
      };
}

/// PRD 6.6 — service data is sensitive operational data, never public.
enum ServiceType {
  water,
  electricity,
  sanitation,
  waste,
  internet,
  roadAccess,
  drainage;

  String get wire => switch (this) {
        ServiceType.water => 'water',
        ServiceType.electricity => 'electricity',
        ServiceType.sanitation => 'sanitation',
        ServiceType.waste => 'waste',
        ServiceType.internet => 'internet',
        ServiceType.roadAccess => 'road_access',
        ServiceType.drainage => 'drainage',
      };

  static ServiceType fromWire(String s) => ServiceType.values.firstWhere(
        (e) => e.wire == s,
        orElse: () => ServiceType.water,
      );
}

class ServiceRecord {
  ServiceRecord({
    required this.structureLocalId,
    required this.serviceType,
    this.source,
    this.supplyFrom,
    this.supplyTo,
    this.quality,
    this.sharedWithCount = 0,
  });

  final String structureLocalId;
  final ServiceType serviceType;
  String? source;
  String? supplyFrom;
  String? supplyTo;
  String? quality;
  int sharedWithCount;

  Map<String, Object?> toPayload() => {
        'structure_id': structureLocalId,
        'service_type': serviceType.wire,
        'source': source,
        'supply_hours': (supplyFrom != null && supplyTo != null)
            ? [[supplyFrom, supplyTo]]
            : null,
        'quality': quality,
        'shared_with_count': sharedWithCount,
      };
}

class LocalStore {
  LocalStore._(this._db, this.siteId);

  final Database _db;
  final String siteId;

  static Future<LocalStore> open() async {
    databaseFactory = databaseFactoryFfi;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'mapper_cache.sqlite');

    final db = await openDatabase(
      dbPath,
      version: 2,
      onConfigure: (d) async {
        await d.execute('PRAGMA journal_mode = WAL');
        await d.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (d, _) async => _applySchema(d),
      onUpgrade: (d, from, to) async => _applySchema(d),
    );

    final siteId = await _ensureSiteId(db);
    return LocalStore._(db, siteId);
  }

  /// Applied idempotently so a version bump is safe to re-run.
  static Future<void> _applySchema(Database d) async {
    const tables = [
      '''
      CREATE TABLE IF NOT EXISTS local_structure (
        local_id TEXT PRIMARY KEY,
        server_id TEXT,
        code TEXT,
        structure_type TEXT NOT NULL DEFAULT 'standalone_dwelling',
        non_residential_subtype TEXT,
        is_shared_wall INTEGER NOT NULL DEFAULT 0,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        entrance_lat REAL,
        entrance_lon REAL,
        entrance_independent INTEGER,
        footprint_json TEXT,
        floors_estimated INTEGER,
        material_primary TEXT,
        occupancy_estimate INTEGER,
        status TEXT NOT NULL DEFAULT 'surveyed',
        disclosure_policy TEXT NOT NULL DEFAULT 'aggregate_only',
        version INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 0,
        last_pulled_at INTEGER NOT NULL DEFAULT 0
      )''',
      '''
      CREATE TABLE IF NOT EXISTS local_service (
        local_id TEXT PRIMARY KEY,
        structure_local_id TEXT NOT NULL,
        service_type TEXT NOT NULL,
        source TEXT,
        supply_from TEXT,
        supply_to TEXT,
        quality TEXT,
        shared_with_count INTEGER NOT NULL DEFAULT 0,
        last_verified_at TEXT,
        still_true_checked_at TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        UNIQUE (structure_local_id, service_type)
      )''',
      '''
      CREATE TABLE IF NOT EXISTS local_photo (
        local_id TEXT PRIMARY KEY,
        structure_local_id TEXT,
        path TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0
      )''',
      '''
      CREATE TABLE IF NOT EXISTS pending_op (
        op_id TEXT PRIMARY KEY,
        seq INTEGER NOT NULL,
        table_name TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        op TEXT NOT NULL CHECK (op IN ('create','update','delete')),
        payload TEXT NOT NULL,
        site_id TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL
      )''',
      'CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      '''
      CREATE TABLE IF NOT EXISTS breadcrumb_point (
        id TEXT PRIMARY KEY,
        trace_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        accuracy_m REAL,
        recorded_at INTEGER NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        UNIQUE (trace_id, seq)
      )''',
      'CREATE INDEX IF NOT EXISTS idx_breadcrumb_trace ON breadcrumb_point(trace_id, seq)',
      '''
      CREATE TABLE IF NOT EXISTS local_grievance (
        local_id TEXT PRIMARY KEY,
        structure_local_id TEXT,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        body TEXT,
        photo_local_id TEXT,
        device_hash TEXT NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )''',
      'CREATE INDEX IF NOT EXISTS idx_pending_op_seq ON pending_op(seq)',
      'CREATE INDEX IF NOT EXISTS idx_local_structure_dirty ON local_structure(dirty)',
    ];
    for (final t in tables) {
      await d.execute(t);
    }
  }

  static Future<String> _ensureSiteId(Database d) async {
    final rows = await d.query('sync_state', where: 'key = ?', whereArgs: ['site_id']);
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final id = _uuid.v4();
    await d.insert('sync_state', {'key': 'site_id', 'value': id});
    return id;
  }

  // ------------------------------------------------------------------ reads

  Future<List<Map<String, Object?>>> allStructures() =>
      _db.query('local_structure', orderBy: 'created_at DESC'.replaceAll('created_at', 'rowid'));

  Future<int> countStructures() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM local_structure')) ?? 0;

  Future<int> pendingCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM pending_op')) ?? 0;

  Future<String?> cursor() async {
    final r = await _db.query('sync_state', where: 'key = ?', whereArgs: ['cursor']);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> setCursor(String? c) async {
    if (c == null) return;
    await _db.insert('sync_state', {'key': 'cursor', 'value': c},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> pendingOps({int limit = 50}) =>
      _db.query('pending_op', orderBy: 'seq ASC', limit: limit);

  // ----------------------------------------------------------------- writes

  /// Capture a structure. Returns its local id. Nothing touches the network.
  Future<String> captureStructure({
    required double lat,
    required double lon,
    required StructureType type,
    String? nonResidentialSubtype,
    double? entranceLat,
    double? entranceLon,
    bool? entranceIndependent,
    bool isSharedWall = false,
    int? floorsEstimated,
    String? materialPrimary,
    int? occupancyEstimate,
    List<ServiceRecord> services = const [],
  }) async {
    final localId = _uuid.v4();
    final now = DateTime.now().toUtc();

    return _db.transaction((txn) async {
      await txn.insert('local_structure', {
        'local_id': localId,
        'code': null,
        'structure_type': type.wire,
        'non_residential_subtype': nonResidentialSubtype,
        'is_shared_wall': isSharedWall ? 1 : 0,
        'lat': lat,
        'lon': lon,
        'entrance_lat': entranceLat,
        'entrance_lon': entranceLon,
        'entrance_independent': entranceIndependent == null ? null : (entranceIndependent ? 1 : 0),
        'floors_estimated': floorsEstimated,
        'material_primary': materialPrimary,
        'occupancy_estimate': occupancyEstimate,
        'status': 'surveyed',
        // PRD 6.6 default; never anything more permissive without a review.
        'disclosure_policy': 'aggregate_only',
        'version': 0,
        'dirty': 1,
        'last_pulled_at': 0,
      });

      for (final s in services) {
        final sid = _uuid.v4();
        await txn.insert('local_service', {
          'local_id': sid,
          'structure_local_id': localId,
          'service_type': s.serviceType.wire,
          'source': s.source,
          'supply_from': s.supplyFrom,
          'supply_to': s.supplyTo,
          'quality': s.quality,
          'shared_with_count': s.sharedWithCount,
          'dirty': 1,
        });
        await _enqueue(txn, 'local_service', sid, 'create', s.toPayload());
      }

      // PRD 6.1 fields are GROUND TRUTH observations: the mapper asserts them,
      // so each carries a Lamport stamp for the field-level CRDT.
      await _enqueue(txn, 'local_structure', localId, 'create', {
        'centroid': {'lat': lat, 'lon': lon},
        'entrance_geom': (entranceLat != null && entranceLon != null)
            ? {'lat': entranceLat, 'lon': entranceLon}
            : null,
        'structure_type': type.wire,
        'entrance_independent': entranceIndependent,
        'is_shared_wall': isSharedWall,
        'floors_estimated': floorsEstimated,
        'material_primary': materialPrimary,
        'occupancy_estimate': occupancyEstimate,
        'observed_at': now.toIso8601String(),
      });

      return localId;
    });
  }

  /// Record a photo. Hashed on capture so a retry is detectable as a duplicate.
  Future<String> attachPhoto(String localId, String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final photoId = _uuid.v4();
    await _db.insert('local_photo', {
      'local_id': photoId,
      'structure_local_id': localId,
      'path': filePath,
      'sha256': digest,
      'uploaded': 0,
    });
    await _db.insert('local_grievance', {
      'local_id': photoId,
      'structure_local_id': localId,
      'lat': 0,
      'lon': 0,
      'body': null,
      'photo_local_id': photoId,
      'device_hash': siteId,
      'uploaded': 0,
      'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _db.delete('local_grievance', where: 'local_id = ?', whereArgs: [photoId]);
    return photoId;
  }

  Future<int> _nextSeq(Transaction txn) async {
    final r = await txn.rawQuery('SELECT COALESCE(MAX(seq), 0) + 1 AS n FROM pending_op');
    return (r.first['n'] as int?) ?? 1;
  }

  Future<void> _enqueue(
    Transaction txn,
    String table,
    String entityId,
    String op,
    Map<String, Object?> payload,
  ) async {
    final seq = await _nextSeq(txn);
    await txn.insert('pending_op', {
      'op_id': '$siteId-$seq',
      'seq': seq,
      'table_name': table,
      'entity_id': entityId,
      'op': op,
      'payload': jsonEncode(payload),
      'site_id': siteId,
      'attempts': 0,
      'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await txn.update('local_structure', {'dirty': 1}, where: 'local_id = ?', whereArgs: [entityId]);
  }

  // ------------------------------------------------------- sync bookkeeping

  /// Acknowledge server-confirmed ops. Only these leave the outbox; a partial
  /// failure leaves the rest queued for the next attempt.
  Future<void> acknowledge(Iterable<String> opIds) async {
    final ids = opIds.toList();
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    // Breadcrumb ops acknowledged by the server are synced locally too.
    await _db.rawUpdate(
        'UPDATE breadcrumb_point SET synced = 1 WHERE trace_id IN (SELECT entity_id FROM pending_op WHERE op_id IN ($placeholders))',
        ids);
    await _db.delete('pending_op', where: 'op_id IN ($placeholders)', whereArgs: ids);
    await _db.insert('sync_state', {
      'key': 'last_sync_at',
      'value': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> recordFailure(String opId, String error) async {
    await _db.update(
      'pending_op',
      {'attempts': 1, 'last_error': error},
      where: 'op_id = ?',
      whereArgs: [opId],
    );
  }

  // ------------------------------------------------------------ breadcrumbs

  /// Record one GPS fix during a walk. Written locally and queued as a
  /// breadcrumb outbox op — sync is opportunistic, never required (C4/C5).
  Future<void> addBreadcrumbPoint({
    required String traceId,
    required int seq,
    required double lat,
    required double lon,
    double? accuracyM,
    required DateTime recordedAt,
  }) async {
    await _db.transaction((txn) async {
      await txn.insert('breadcrumb_point', {
        'id': _uuid.v4(),
        'trace_id': traceId,
        'seq': seq,
        'lat': lat,
        'lon': lon,
        'accuracy_m': accuracyM,
        'recorded_at': recordedAt.toUtc().millisecondsSinceEpoch,
        'synced': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      // Queue one op per point; the server dedupes by (device, trace, seq)
      // and by clientOpId, so a replay cannot duplicate points.
      final opSeq = await _nextSeq(txn);
      await txn.insert('pending_op', {
        'op_id': '$siteId-bc-$opSeq',
        'seq': opSeq,
        'table_name': 'breadcrumb',
        'entity_id': traceId,
        'op': 'create',
        'payload': jsonEncode({
          'trace_id': traceId,
          'points': [
            {
              'lat': lat, 'lon': lon, 'accuracy_m': accuracyM,
              'seq': seq, 'recorded_at': recordedAt.toUtc().toIso8601String(),
            }
          ],
        }),
        'site_id': siteId,
        'attempts': 0,
        'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
    });
  }

  Future<List<Map<String, Object?>>> allBreadcrumbs() =>
      _db.query('breadcrumb_point', orderBy: 'recorded_at ASC');

  Future<int> breadcrumbCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM breadcrumb_point')) ?? 0;

  Future<int> unsyncedBreadcrumbCount() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM breadcrumb_point WHERE synced = 0')) ?? 0;

  /// Haversine distance of the recorded walk, in metres.
  Future<double> walkDistanceM() async {
    final rows = await allBreadcrumbs();
    var total = 0.0;
    for (var i = 1; i < rows.length; i++) {
      final aLat = (rows[i - 1]['lat'] as num).toDouble();
      final aLon = (rows[i - 1]['lon'] as num).toDouble();
      final bLat = (rows[i]['lat'] as num).toDouble();
      final bLon = (rows[i]['lon'] as num).toDouble();
      const r = 6371000.0;
      final dLat = (bLat - aLat) * math.pi / 180;
      final dLon = (bLon - aLon) * math.pi / 180;
      final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
          math.cos(aLat * math.pi / 180) *
              math.cos(bLat * math.pi / 180) *
              math.sin(dLon / 2) *
              math.sin(dLon / 2);
      total += 2 * r * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
    }
    return total;
  }

  Future<void> close() => _db.close();
}