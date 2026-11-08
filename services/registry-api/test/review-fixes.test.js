// Regression tests for review fixes: dispatch validation, sync update, pull cursor.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const { Registry } = require('../src/registry.js');
const { InternalBackend } = require('../src/dispatch.js');

function setup() {
  const registry = new Registry(':memory:');
  registry.db.prepare(
    `INSERT INTO zone (code, name, lat, lon, radius_m, dispatch_enabled)
     VALUES ('C4', 'Campus', 12.97, 77.59, 2000, 1)`).run();
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'rev-1' });
  return { registry, s, code };
}

test('assign rejects an unknown code', async () => {
  const { registry } = setup();
  const b = new InternalBackend({ registry });
  const out = await b.dispatch('SLR-FAKE', { responder: 'u1' });
  assert.strictEqual(out.error, 'structure_not_found');
  assert.strictEqual(out.http, 404);
});

test('outcome rejects an unknown dispatch and an invalid outcome value', async () => {
  const { registry, code } = setup();
  const b = new InternalBackend({ registry });
  const missing = await b.outcome('nope', { outcome: 'confirmed' });
  assert.strictEqual(missing.error, 'dispatch_not_found');
  const assigned = await b.dispatch(code, { responder: 'u1' });
  const bad = await b.outcome(assigned.dispatch_id, { outcome: 'teleported' });
  assert.strictEqual(bad.error, 'invalid_outcome');
});

test('outcome normalises reached to confirmed', async () => {
  const { registry, code } = setup();
  const b = new InternalBackend({ registry });
  const assigned = await b.dispatch(code, { responder: 'u1' });
  const done = await b.outcome(assigned.dispatch_id, { outcome: 'reached' });
  assert.strictEqual(done.recorded, true);
  const row = registry.db.prepare('SELECT outcome FROM dispatcher_outcomes WHERE dispatch_id = ?').get(assigned.dispatch_id);
  assert.strictEqual(row.outcome, 'confirmed');
});

test('sync update to a confirmed structure actually applies the field', () => {
  const { registry, s } = setup();
  const res = registry.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [{
      clientOpId: 'u1', clientSeq: 1, table: 'local_structure', op: 'update',
      entityId: s,
      payload: { fields: { floors_estimated: { value: 4, lamport: 2, siteId: 'm1' } } },
    }],
  });
  assert.strictEqual(res.results[0].state, 'applied');
  assert.strictEqual(registry.getStructure(s).floors_estimated, 4);
});

test('pull honours the cursor: a second pull returns nothing new', () => {
  const { registry } = setup();
  const first = registry.pull({ limit: 10 });
  assert.ok(first.changes.length > 0);
  const second = registry.pull({ since: first.cursor, limit: 10 });
  assert.strictEqual(second.changes.length, 0);
});
