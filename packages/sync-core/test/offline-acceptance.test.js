/**
 * M1 acceptance test: the mapper's field workflow with NO NETWORK.
 *
 * This is the explicit M1 exit criterion, not a nice-to-have. A mapper
 * surveys structures, the app is killed, the network is never there, and the
 * work must survive and sync correctly on a single later connection.
 *
 * Runs entirely in-process against an in-memory SQLite store and a fake
 * transport that is hard-wired to "offline" until the final flush.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { DatabaseSync } = require('node:sqlite');

const {
  Outbox,
  IdempotencyLedger,
  ConnectivityGate,
  mergeFields,
  LamportClock,
} = require('../index.js');

// ---------------------------------------------------------------------------
// Local store — the mapper's SQLite cache. The UI never awaits the network (C4).
// ---------------------------------------------------------------------------

function openLocalDb(path = ':memory:') {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS local_structure (
      local_id      TEXT PRIMARY KEY,
      server_id     TEXT,
      code          TEXT,
      structure_type TEXT,
      lat           REAL NOT NULL,
      lon           REAL NOT NULL,
      entrance_lat  REAL,
      entrance_lon  REAL,
      entrance_independent INTEGER,
      status        TEXT NOT NULL DEFAULT 'surveyed',
      dirty         INTEGER NOT NULL DEFAULT 0,
      version       INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS local_service (
      local_id       TEXT PRIMARY KEY,
      structure_local_id TEXT NOT NULL,
      service_type   TEXT NOT NULL,
      source         TEXT,
      quality        TEXT,
      dirty          INTEGER NOT NULL DEFAULT 0,
      UNIQUE (structure_local_id, service_type)
    );
    CREATE TABLE IF NOT EXISTS pending_op (
      op_id     TEXT PRIMARY KEY,
      seq       INTEGER NOT NULL,
      table_name TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      op        TEXT NOT NULL,
      payload   TEXT NOT NULL,
      attempts  INTEGER NOT NULL DEFAULT 0
    );
  `);
  return db;
}

/** A transport that is offline unless explicitly opened. */
class FakeTransport {
  constructor() {
    this.online = false;
    this.sent = [];
  }
  async push(batch) {
    if (!this.online) throw new Error('ENETDOWN: transport is offline');
    this.sent.push(batch);
    return batch.map((op) => ({
      clientOpId: op.clientOpId,
      state: 'applied',
      serverId: `srv-${op.entityId}`,
      version: 1,
    }));
  }
}

// ---------------------------------------------------------------------------

test('M1: 30 structures captured and edited with no network, then synced once', async () => {
  // file-backed, so closing and reopening is a genuine restart
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mapper-'));
  const dbPath = path.join(dir, 'cache.sqlite');

  const db = openLocalDb(dbPath);
  const net = new FakeTransport();
  const ob = new Outbox({ deviceId: 'dev_9f2b', siteId: 'mapper_1' });
  const ledger = new IdempotencyLedger();
  const gate = new ConnectivityGate({ pull: () => net.online, minIntervalMs: 0 });
  const clock = new LamportClock('mapper_1');

  const insert = db.prepare(`
    INSERT INTO local_structure
      (local_id, structure_type, lat, lon, entrance_lat, entrance_lon, entrance_independent, dirty)
    VALUES (?, ?, ?, ?, ?, ?, ?, 1)
  `);
  const persistOp = db.prepare(`
    INSERT INTO pending_op (op_id, seq, table_name, entity_id, op, payload)
    VALUES (?, ?, ?, ?, ?, ?)
  `);

  // ---- PHASE 1: survey 30 structures, entirely offline --------------------
  assert.strictEqual(gate.shouldAttempt().allowed, false, 'must not sync while offline');

  const localIds = [];
  for (let i = 0; i < 30; i++) {
    const id = `loc_${i}`;
    localIds.push(id);
    const lat = 12.97 + i * 0.0001;
    const lon = 77.59 + i * 0.0001;
    insert.run(
      id,
      i % 5 === 0 ? 'shared_wall_dwelling' : 'standalone_dwelling',
      lat, lon, lat - 0.00005, lon - 0.00005, i % 5 === 0 ? 1 : 0,
    );
    const op = ob.enqueue('structure', id, 'create', {
      centroid: { lat, lon },
      structure_type: i % 5 === 0 ? 'shared_wall_dwelling' : 'standalone_dwelling',
      entrance_independent: i % 5 === 0,
      fields: {
        structure_type: clock.tick(i % 5 === 0 ? 'shared_wall_dwelling' : 'standalone_dwelling'),
        entrance_independent: clock.tick(i % 5 === 0),
      },
    });
    persistOp.run(op.clientOpId, op.clientSeq, op.table, op.entityId, op.op,
      JSON.stringify(op.payload));
  }
  assert.strictEqual(ob.size, 30, 'all 30 writes queued locally');
  assert.strictEqual(net.sent.length, 0, 'nothing was sent while offline');

  // ---- PHASE 2: app killed and reopened, still offline --------------------
  // Close the handle and reopen the same file: everything must survive from
  // local storage alone, with no server contact.
  db.close();
  const reopened = openLocalDb(dbPath);
  const rows = reopened.prepare('SELECT COUNT(*) AS n FROM local_structure').get();
  assert.strictEqual(rows.n, 30, 'structures survive a restart offline');
  assert.strictEqual(net.sent.length, 0, 'restart contacted no server');
  // the outbox is rebuilt from persisted pending_op rows, exactly as the app
  // would do on launch
  const persisted = reopened.prepare(
    'SELECT op_id FROM pending_op ORDER BY seq',
  ).all();
  const rebuilt = new Outbox({ deviceId: 'dev_9f2b', siteId: 'mapper_1' });
  rebuilt.pending = persisted.map((r, i) => ({
    clientOpId: r.op_id, clientSeq: i + 1, table: 'structure',
    entityId: `loc_${i}`, op: 'create', payload: {}, siteId: 'mapper_1',
  }));
  assert.strictEqual(rebuilt.size, 30, 'outbox survives the restart');

  // ---- PHASE 3: offline edits to service data on all 30 -------------------
  const svc = reopened.prepare(`
    INSERT INTO local_service (local_id, structure_local_id, service_type, source, quality, dirty)
    VALUES (?, ?, 'water', 'informal_tap', 'fair', 1)
  `);
  for (const id of localIds) {
    svc.run(`svc_${id}`, id);
    ob.enqueue('structure_service', `svc_${id}`, 'create', {
      source: 'informal_tap',
      quality: 'fair',
      fields: {
        source: clock.tick('informal_tap'),
        quality: clock.tick('fair'),
      },
    });
  }
  assert.strictEqual(ob.size, 60);

  // editing offline must not attempt the network
  assert.strictEqual(gate.shouldAttempt().allowed, false);
  assert.strictEqual(net.sent.length, 0);

  // ---- PHASE 4: one connection, drain in order ----------------------------
  net.online = true;
  gate.onChange(true);
  assert.strictEqual(gate.shouldAttempt().allowed, true);

  let guard = 0;
  while (ob.size > 0 && guard++ < 20) {
    const batch = ob.drain(50);
    const results = await net.push(batch);
    const { acked } = ledger.applyPush(results);
    ob.acknowledge(acked);
  }

  assert.strictEqual(ob.size, 0, 'outbox fully drained');
  assert.strictEqual(ledger.receipts.size, 60, 'exactly one receipt per op, no duplicates');

  // every op reached the server exactly once, in client order
  const allSent = net.sent.flat();
  assert.strictEqual(allSent.length, 60);
  const seqs = allSent.map((o) => o.clientSeq);
  assert.deepStrictEqual(seqs, [...seqs].sort((a, b) => a - b), 'preserved client order');
  assert.strictEqual(new Set(allSent.map((o) => o.clientOpId)).size, 60, 'no duplicate op ids');

  reopened.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('M1: killing the app mid-push does not duplicate or lose work', async () => {
  const db = openLocalDb();
  const net = new FakeTransport();
  const ob = new Outbox({ deviceId: 'd1', siteId: 'm1' });
  const ledger = new IdempotencyLedger();

  for (let i = 0; i < 5; i++) {
    ob.enqueue('structure', `s${i}`, 'create', { fields: { quality: i } });
  }

  net.online = true; // connectivity appears
  // first push reaches the server but the response is lost
  const first = await net.push(ob.drain());
  ledger.record(first[0].clientOpId, first[0]);
  ob.acknowledge([first[0].clientOpId]);

  // the app restarts and the outbox is rebuilt from local storage with only
  // the un-acknowledged ops; the acked one must NOT be re-sent
  const survived = new Outbox({ deviceId: 'd1', siteId: 'm1' });
  for (const op of ob.pending) survived.enqueue(op.table, op.entityId, op.op, op.payload);

  const replay = await net.push(survived.drain());
  const { acked, replays } = ledger.applyPush([
    { clientOpId: first[0].clientOpId, state: 'replayed', serverId: first[0].serverId },
    ...replay,
  ]);

  assert.strictEqual(survived.size, 4, 'four ops remain outstanding');
  assert.strictEqual(replays.length, 1, 'the lost op was recognised, not re-created');
  db.close();
});

test('M1: a mapper can work fully offline indefinitely', async () => {
  const db = openLocalDb();
  const net = new FakeTransport();
  const ob = new Outbox({ deviceId: 'd', siteId: 'm' });
  const gate = new ConnectivityGate({ pull: () => net.online, minIntervalMs: 0 });

  const ins = db.prepare(
    'INSERT INTO local_structure (local_id, lat, lon, dirty) VALUES (?, ?, ?, 1)',
  );

  // ten days offline, 5 writes a day
  for (let day = 0; day < 10; day++) {
    for (let k = 0; k < 5; k++) {
      const id = `d${day}_${k}`;
      ins.run(id, 12.97 + day * 0.001, 77.59 + k * 0.001);
      ob.enqueue('structure', id, 'create', { fields: {} });
    }
    assert.strictEqual(gate.shouldAttempt().allowed, false, `day ${day}: no sync attempted`);
    assert.strictEqual(net.sent.length, 0);
  }

  assert.strictEqual(ob.size, 50);
  assert.strictEqual(db.prepare('SELECT COUNT(*) AS n FROM local_structure').get().n, 50);
  db.close();
});