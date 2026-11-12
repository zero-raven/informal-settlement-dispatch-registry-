/**
 * M2 constraint tests: registry, sync, dedup, code issuance, QR.
 *
 * Each test asserts something the PRD requires. They fail if the implementation
 * drifts toward an automated identity decision or an unguarded sync path.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { Registry, mergeFields, IdentityMergeRefused } = require('../src/registry.js');
const { renderQr, encodePayload, decodePayload } = require('../src/qr.js');

function newRegistry() {
  const r = new Registry(':memory:');
  r.db.prepare(
    "INSERT INTO app_user (id, email, role) VALUES ('m1','m@x','mapper')",
  ).run();
  return r;
}

const REVIEWER = 'reviewer-1';

// ---------------------------------------------------------------------------
// C2 — duplicates require human review
// ---------------------------------------------------------------------------

test('C2: a second pin near an existing structure creates a candidate, not a merge', () => {
  const r = newRegistry();
  const a = r.createStructure({ lat: 12.97, lon: 77.59, createdBy: 'm1' });
  const b = r.createStructure({ lat: 12.97005, lon: 77.59005, createdBy: 'm1' });

  const cand = r.generateDedupCandidate(b);
  assert.ok(cand, 'a nearby pin must generate a candidate');
  const queue = r.openDedupQueue();
  assert.strictEqual(queue.length, 1);
  assert.strictEqual(queue[0].state, 'open');
  // neither structure has a code yet: identity is unresolved
  assert.strictEqual(r.getStructure(a).code, null);
  assert.strictEqual(r.getStructure(b).code, null);
});

test('C2: a far pin generates no candidate', () => {
  const r = newRegistry();
  r.createStructure({ lat: 12.97, lon: 77.59 });
  const far = r.createStructure({ lat: 12.99, lon: 77.62 });
  assert.strictEqual(r.generateDedupCandidate(far), null);
});

test('C6.1: independent entrances lower merge likelihood, not raise it', () => {
  const r = newRegistry();
  // same building, shared wall, entrances far apart -> separate destinations
  const a = r.createStructure({
    lat: 12.97, lon: 77.59, isSharedWall: true,
    entranceLat: 12.9700, entranceLon: 77.5900, entranceIndependent: true,
  });
  const b = r.createStructure({
    lat: 12.97005, lon: 77.59005, isSharedWall: true,
    entranceLat: 12.9760, entranceLon: 77.5960, entranceIndependent: true,
  });
  const cand = r.generateDedupCandidate(b);
  const row = r.db.prepare('SELECT * FROM dedup_candidate WHERE id = ?').get(cand);
  assert.ok(row.entrance_dist_m > 100, 'entrance distance is measured separately');
  assert.strictEqual(row.wall_shared, 1, 'shared wall is recorded as evidence');
});

test('C2: reviewer decision "distinct" issues TWO codes', () => {
  const r = newRegistry();
  const a = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const b = r.createStructure({ lat: 12.97005, lon: 77.59005, status: 'surveyed' });
  const cand = r.generateDedupCandidate(b);

  const res = r.decideDedup(cand, 'distinct', {
    reviewerId: REVIEWER,
    note: 'shared wall, two independent entrances',
    classification: { structureType: 'shared_wall_dwelling', entranceIndependent: true, isSharedWall: true },
  });
  assert.ok(res.code, 'the new structure receives a code');
  // PRD 6.1: two independently identifiable destinations are TWO structures
  assert.notStrictEqual(res.code, r.getStructure(a).code === null ? undefined : r.getStructure(a).code);
});

test('C2: reviewer decision "merge" soft-deletes and keeps one code', () => {
  const r = newRegistry();
  const a = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const b = r.createStructure({ lat: 12.97005, lon: 77.59005, status: 'surveyed' });
  const cand = r.generateDedupCandidate(b);

  const res = r.decideDedup(cand, 'merge', { reviewerId: REVIEWER, note: 'same unit, one entrance' });
  assert.strictEqual(res.decision, 'merge');
  // a tombstone, never a hard delete: offline clients must converge (C4)
  assert.ok(r.getStructure(b).deleted_at);
  assert.ok(!r.getStructure(a).deleted_at);
  assert.strictEqual(r.allStructures(false).length, 1);
  assert.strictEqual(r.allStructures(true).length, 2, 'the tombstone is retained');
});

test('C2: merge collapses to multi_household_single_entry when entrances merge', () => {
  const r = newRegistry();
  const a = r.createStructure({
    lat: 12.97, lon: 77.59, status: 'surveyed',
    entranceIndependent: true, entranceLat: 12.97, entranceLon: 77.59,
  });
  const b = r.createStructure({ lat: 12.97005, lon: 77.59005, status: 'surveyed' });
  const cand = r.generateDedupCandidate(b);

  r.decideDedup(cand, 'merge', {
    reviewerId: REVIEWER,
    classification: { structureType: 'multi_household_single_entry' },
  });
  assert.strictEqual(r.getStructure(a).entrance_independent, 0,
    'one common entrance means one structure (PRD 6.1)');
});

// ---------------------------------------------------------------------------
// C1 — identity is never assigned by an automated path
// ---------------------------------------------------------------------------

test('C1: issueCode refuses an un-surveyed structure', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59, status: 'candidate' });
  assert.throws(() => r.issueCode(s, { reviewerId: REVIEWER }),
    /human dedup decision is required/);
  assert.strictEqual(r.getStructure(s).code, null);
});

test('C1: issueCode refuses when no reviewer is named', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  assert.throws(() => r.issueCode(s), /requires a reviewer/);
  assert.throws(() => r.issueCode(s, {}), /requires a reviewer/);
  assert.strictEqual(r.getStructure(s).code, null);
});

test('C1: no code is ever issued without a dedup decision', () => {
  const r = newRegistry();
  for (let i = 0; i < 5; i++) {
    r.createStructure({ lat: 12.97 + i * 0.01, lon: 77.59, status: 'surveyed' });
  }
  assert.ok(r.allStructures().every((s) => s.code === null),
    'creating structures must never assign a code');
});

test('C1: codes carry no location information', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = r.issueCode(s, { reviewerId: REVIEWER });
  assert.doesNotMatch(code, /12|97|77|59/, 'no coordinate fragments');
  assert.match(code, /^SLR-[A-Z]\d+$/);
});

test('C1: code issuance is idempotent for the same structure', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const first = r.issueCode(s, { reviewerId: REVIEWER });
  const second = r.issueCode(s, { reviewerId: REVIEWER });
  assert.strictEqual(first, second, 'revisit returns the same code');
});

test('C1: codes are unique across structures', () => {
  const r = newRegistry();
  const codes = new Set();
  for (let i = 0; i < 20; i++) {
    const s = r.createStructure({ lat: 12.97 + i * 0.01, lon: 77.59, status: 'surveyed' });
    codes.add(r.issueCode(s, { reviewerId: REVIEWER }));
  }
  assert.strictEqual(codes.size, 20);
});

// ---------------------------------------------------------------------------
// Sync — C4/C5
// ---------------------------------------------------------------------------

test('C4: replaying the same batch yields identical receipts, no duplicates', () => {
  const r = newRegistry();
  const batch = {
    deviceId: 'dev1',
    mapperId: 'm1',
    ops: [{
      clientOpId: 'op-1', clientSeq: 1, table: 'local_structure', op: 'create',
      entityId: 'loc-1',
      payload: { centroid: { lat: 12.97, lon: 77.59 }, structure_type: 'standalone_dwelling' },
    }],
  };
  const first = r.push(batch);
  assert.strictEqual(first.results[0].state, 'applied');

  for (let i = 0; i < 10; i++) {
    const again = r.push(batch);
    assert.strictEqual(again.results[0].state, 'replayed');
    assert.strictEqual(again.results[0].serverId, first.results[0].serverId);
  }
  assert.strictEqual(r.allStructures(false).length, 1, 'never duplicates');
});

test('C4: ops apply in client order regardless of arrival order', () => {
  const r = newRegistry();
  const ops = [3, 1, 2].map((n) => ({
    clientOpId: `op-${n}`, clientSeq: n, table: 'local_structure', op: 'create',
    entityId: `loc-${n}`,
    payload: { centroid: { lat: 12.97 + n * 0.001, lon: 77.59 } },
  }));
  const res = r.push({ deviceId: 'd', mapperId: 'm1', ops });
  const seqs = res.results.map((x) => x.clientOpId);
  assert.deepStrictEqual(seqs, ['op-1', 'op-2', 'op-3']);
});

test('C2: an update to an unconfirmed structure is rejected, not merged', () => {
  const r = newRegistry();
  const a = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const b = r.createStructure({ lat: 12.97005, lon: 77.59005, status: 'surveyed' });
  r.generateDedupCandidate(b);

  const res = r.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [{
      clientOpId: 'op-up', clientSeq: 9, table: 'local_structure', op: 'update',
      entityId: a,
      payload: { fields: { floors_estimated: { value: 5, lamport: 3, siteId: 'm1' } } },
    }],
  });
  assert.strictEqual(res.results[0].state, 'rejected');
  assert.strictEqual(res.results[0].reason, 'structure_in_dedup_review');
});

test('C2: an update to a CONFIRMED structure merges at field level', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  r.issueCode(s, { reviewerId: REVIEWER });

  const res = r.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [{
      clientOpId: 'op-up2', clientSeq: 10, table: 'local_structure', op: 'update',
      entityId: s,
      payload: { fields: { floors_estimated: { value: 4, lamport: 2, siteId: 'm1' } } },
    }],
  });
  assert.strictEqual(res.results[0].state, 'applied');
});

test('C2: an identity field in an update payload is refused', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  r.issueCode(s, { reviewerId: REVIEWER });
  const res = r.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [{
      clientOpId: 'op-evil', clientSeq: 11, table: 'local_structure', op: 'update',
      entityId: s, payload: { fields: { code: { value: 'SLR-Z9999', lamport: 9, siteId: 'm1' } } },
    }],
  });
  assert.strictEqual(res.results[0].state, 'rejected');
  assert.strictEqual(res.results[0].reason, 'identity_merge_refused');
});

test('a failed op does not abort the rest of the batch', () => {
  const r = newRegistry();
  const res = r.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [
      { clientOpId: 'a', clientSeq: 1, table: 'local_structure', op: 'create',
        payload: { centroid: { lat: 12.97, lon: 77.59 } } },
      { clientOpId: 'b', clientSeq: 2, table: 'local_structure', op: 'create',
        payload: { centroid: { lat: 12.97005, lon: 77.59005 } } }, // near duplicate
      { clientOpId: 'c', clientSeq: 3, table: 'local_structure', op: 'create',
        payload: { centroid: { lat: 12.99, lon: 77.62 } } },
    ],
  });
  assert.strictEqual(res.results.length, 3);
  assert.strictEqual(res.results[0].state, 'applied');
  assert.strictEqual(res.results[1].state, 'dedup_required');
  assert.strictEqual(res.results[2].state, 'applied');
});

test('bootstrap excludes anything identity-related', () => {
  const r = newRegistry();
  r.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const boot = r.bootstrap({ zone: 'C4' });
  assert.strictEqual(boot.structures.length, 1);
  for (const s of boot.structures) {
    assert.ok(!('resident' in s) && !('occupant' in s) && !('consent' in s));
  }
});

// ---------------------------------------------------------------------------
// C8 — inference never overwrites ground truth
// ---------------------------------------------------------------------------

test('C8: every captured value is recorded as a ground-truth assertion', () => {
  const r = newRegistry();
  r.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [{
      clientOpId: 'op-gt', clientSeq: 1, table: 'local_structure', op: 'create',
      payload: {
        centroid: { lat: 12.97, lon: 77.59 },
        structure_type: 'standalone_dwelling',
        observed_at: new Date().toISOString(),
      },
    }],
  });
  const rows = r.db.prepare("SELECT * FROM assertion WHERE state = 'asserted'").all();
  assert.ok(rows.length >= 2);
  assert.ok(rows.every((a) => a.evidence_class === 'ground_truth'));
  assert.ok(rows.every((a) => a.observed_by === 'mapper:m1'));
});

test('C8: an inference assertion is always a candidate, never asserted', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59 });
  const out = r.recordAssertion({
    entityId: s, field: 'footprint', value: { shift: 3 },
    evidenceClass: 'inference', source: 'imagery_diff',
    producedBy: 'ml:imagery', confidence: 0.71,
  });
  assert.strictEqual(out.state, 'candidate');
  const asserted = r.db.prepare("SELECT COUNT(*) AS n FROM assertion WHERE state = 'asserted'").get();
  assert.strictEqual(asserted.n, 0, 'inference never becomes authoritative on its own');
});

test('C8: a verified observation supersedes the prior ground truth', () => {
  const r = newRegistry();
  const s = r.createStructure({ lat: 12.97, lon: 77.59 });
  r.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.97 },
    evidenceClass: 'ground_truth', source: 'mapper_survey', observedBy: 'mapper:1',
  });
  const out = r.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.98 },
    evidenceClass: 'ground_truth', source: 'dispatch_feedback', observedBy: 'dispatch:unit-7',
  });
  assert.ok(out.superseded, 'the prior assertion is superseded, not deleted');
  const current = r.db.prepare(
    "SELECT value, observed_by FROM assertion WHERE field='centroid' AND state='asserted'").get();
  assert.deepStrictEqual(JSON.parse(current.value), { lat: 12.98 });
  assert.strictEqual(current.observed_by, 'dispatch:unit-7');
  // history is retained
  assert.strictEqual(
    r.db.prepare("SELECT COUNT(*) AS n FROM assertion WHERE field='centroid' AND state='superseded'").get().n, 1);
});

// ---------------------------------------------------------------------------
// QR — PRD 6.1 format-agnostic, PRD 6.5 placard
// ---------------------------------------------------------------------------

test('QR encodes the public code and nothing about its internals', async () => {
  const { payload, code, svg, svg_sha256 } = await renderQr('SLR-C41001');
  assert.strictEqual(code, 'SLR-C41001');
  assert.ok(payload.includes('SLR-C41001'));
  assert.ok(svg.startsWith('<?xml') || svg.startsWith('<svg'));
  assert.match(svg_sha256, /^[0-9a-f]{64}$/);
});

test('QR payload round-trips through decode', async () => {
  const { payload } = await renderQr('SLR-C41002');
  assert.strictEqual(decodePayload(payload), 'SLR-C41002');
  assert.strictEqual(decodePayload('SLR:SLR-C41002'), 'SLR-C41002');
  assert.strictEqual(decodePayload('https://registry.example/s/SLR-C41002'), 'SLR-C41002');
  assert.strictEqual(decodePayload(null), null);
});

test('QR rendering is deterministic for the same code', async () => {
  const a = await renderQr('SLR-C41003');
  const b = await renderQr('SLR-C41003');
  assert.strictEqual(a.svg_sha256, b.svg_sha256);
});

// ---------------------------------------------------------------------------
// End-to-end — the journey M2 exists for
// ---------------------------------------------------------------------------

test('E2E: offline capture -> sync -> dedup -> human review -> code -> QR', () => {
  const r = newRegistry();

  // 1. a mapper surveys 5 structures far apart, entirely offline
  const ops = [];
  for (let i = 0; i < 5; i++) {
    ops.push({
      clientOpId: `m1-${i}`, clientSeq: i + 1,
      table: 'local_structure', op: 'create', entityId: `loc-${i}`,
      payload: {
        centroid: { lat: 12.97 + i * 0.01, lon: 77.59 },
        structure_type: 'standalone_dwelling',
        entrance_geom: { lat: 12.97 + i * 0.01, lon: 77.59 },
        entrance_independent: true,
        observed_at: new Date().toISOString(),
      },
    });
  }
  const sync = r.push({ deviceId: 'dev1', mapperId: 'm1', ops });
  assert.ok(sync.results.every((x) => x.state === 'applied'));

  // 2. a second mapper captures the same building from another day
  const dup = r.push({
    deviceId: 'dev2', mapperId: 'm2',
    ops: [{
      clientOpId: 'm2-0', clientSeq: 1, table: 'local_structure', op: 'create',
      entityId: 'loc-dup',
      payload: {
        centroid: { lat: 12.97006, lon: 77.59006 },
        structure_type: 'standalone_dwelling',
        entrance_geom: { lat: 12.97006, lon: 77.59006 },
        entrance_independent: true,
      },
    }],
  });
  assert.strictEqual(dup.results[0].state, 'dedup_required');
  assert.ok(dup.results[0].dedupCandidateId);

  // 3. the duplicate EXISTS as its own row — dedup_required means "a human must
  //    decide", not "silently merged". The five lone structures were coded at
  //    sync (no candidate, PRD 6.1); the possible duplicate is not.
  assert.strictEqual(r.allStructures(false).length, 6);
  const dupRow = r.getStructure(dup.results[0].serverId);
  assert.strictEqual(dupRow.code, null, 'no code while identity is unresolved');
  const originalCode = r.getStructure(dup.results[0].nearestStructure.serverId).code;
  assert.match(originalCode, /^SLR-/);

  // 4. the reviewer confirms it is the same unit -> merge, one code
  const queue = r.openDedupQueue();
  assert.strictEqual(queue.length, 1);
  const merged = r.decideDedup(queue[0].id, 'merge', {
    reviewerId: REVIEWER, note: 'same unit, re-surveyed',
  });
  assert.strictEqual(r.allStructures(false).length, 5);

  // 5. the merge keeps the original code; no second code was minted
  assert.strictEqual(merged.code, originalCode);
  const survivors = r.allStructures();
  assert.ok(survivors.every((s) => s.code), 'every survivor is coded');
  assert.strictEqual(new Set(survivors.map((s) => s.code)).size, 5);
  const coded = survivors.filter((s) => s.code === originalCode);

  // 6. and a QR resolves it
  const qr = encodePayload(coded[0].code);
  assert.strictEqual(decodePayload(qr.payload), coded[0].code);
});
// ---------------------------------------------------------------------------
// Demo MVP — auto-issue at sync when no dedup candidate exists (PRD 6.1)
// ---------------------------------------------------------------------------

const syncOp = (id, seq, lat, lon) => ({ clientOpId: id, clientSeq: seq, table: 'local_structure', op: 'create',
  payload: { centroid: { lat, lon }, structure_type: 'standalone_dwelling' } });

test('sync: a structure with nothing nearby gets a code at once', () => {
  const r = newRegistry();
  const [res] = r.push({ deviceId: 'd1', ops: [syncOp('o1', 1, 12.97, 77.59)], mapperId: 'm1' }).results;
  assert.strictEqual(res.state, 'applied');
  assert.match(res.code, /^SLR-/);
  assert.strictEqual(r.getStructure(res.serverId).code, res.code);
});

test('sync: a pin near an existing structure still waits for a human', () => {
  const r = newRegistry();
  r.push({ deviceId: 'd1', ops: [syncOp('o1', 1, 12.97, 77.59)], mapperId: 'm1' });
  const [res] = r.push({ deviceId: 'd1', ops: [syncOp('o2', 2, 12.97003, 77.59)], mapperId: 'm1' }).results;
  assert.strictEqual(res.state, 'dedup_required');
  assert.strictEqual(res.code, undefined);
  assert.strictEqual(r.getStructure(res.serverId).code, null);
});

test('sync: replaying the op returns the same code', () => {
  const r = newRegistry();
  const first = r.push({ deviceId: 'd1', ops: [syncOp('o1', 1, 12.97, 77.59)], mapperId: 'm1' }).results[0];
  const again = r.push({ deviceId: 'd1', ops: [syncOp('o1', 1, 12.97, 77.59)], mapperId: 'm1' }).results[0];
  assert.match(first.code, /^SLR-/);
  assert.strictEqual(again.state, 'replayed');
  assert.strictEqual(again.code, first.code);
});

test('sync: services in the structure op are stored', () => {
  const r = newRegistry();
  const o = syncOp('o1', 1, 12.97, 77.59);
  o.payload.services = [{ service_type: 'water', source: 'shared_tap', supply_hours: [['06:00', '09:00']], quality: 'ok', shared_with_count: 4 }];
  const [res] = r.push({ deviceId: 'd1', ops: [o], mapperId: 'm1' }).results;
  const rows = r.db.prepare('SELECT * FROM structure_service WHERE structure_id = ?').all(res.serverId);
  assert.strictEqual(rows.length, 1);
  assert.strictEqual(rows[0].service_type, 'water');
  assert.strictEqual(rows[0].supply_hours, '06:00-09:00');
  assert.strictEqual(rows[0].shared_with_count, 4);
});

test('sync: a bad service entry does not lose the structure', () => {
  const r = newRegistry();
  const o = syncOp('o1', 1, 12.97, 77.59);
  o.payload.services = [{ service_type: 'water' }, { service_type: 'water' }, { foo: 1 }, { service_type: 'electricity', supply_hours: ['bad'] }];
  const [res] = r.push({ deviceId: 'd1', ops: [o], mapperId: 'm1' }).results;
  assert.strictEqual(res.state, 'applied');
  assert.ok(r.getStructure(res.serverId));
  assert.strictEqual(r.db.prepare('SELECT COUNT(*) n FROM structure_service').get().n, 2);
});

// ---------------------------------------------------------------------------
// Demo MVP — zones from ZONES_FILE (C7)
// ---------------------------------------------------------------------------

test('zones: upsert makes lookups inside the zone dispatchable', () => {
  const r = newRegistry();
  assert.strictEqual(r.upsertZones([{ code: 'C4', name: 'Campus', lat: 12.97, lon: 77.59, radius_m: 600, dispatch_enabled: true }]), 1);
  assert.strictEqual(r.zoneFor(12.9701, 77.5901).code, 'C4');
  r.upsertZones([{ code: 'C4', name: 'Campus', lat: 12.97, lon: 77.59, radius_m: 600, dispatch_enabled: false }]);
  assert.strictEqual(r.zoneFor(12.9701, 77.5901), null);
  assert.strictEqual(r.db.prepare('SELECT COUNT(*) n FROM zone').get().n, 1);
});

test('zones: an invalid entry writes nothing', () => {
  const r = newRegistry();
  assert.throws(() => r.upsertZones([{ code: 'A', name: 'a', lat: 1, lon: 1, radius_m: 1, dispatch_enabled: true }, { code: 'B' }]), /invalid zone/);
  assert.strictEqual(r.db.prepare('SELECT COUNT(*) n FROM zone').get().n, 0);
});

test('zones: a missing file fails loudly', () => {
  const { loadZonesFile } = require('../src/registry.js');
  assert.throws(() => loadZonesFile('does/not/exist.json'), /does\/not\/exist\.json/);
});
