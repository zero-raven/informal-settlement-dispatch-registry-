// Breadcrumb sync: offline GPS points reach the backend and are listed for mapping.
'use strict';

const assert = require('node:assert');
const test = require('node:test');
const { Registry } = require('../src/registry.js');

test('breadcrumb op stores points and is idempotent on replay', () => {
  const r = new Registry(':memory:');
  const op = {
    clientOpId: 'bc-1', clientSeq: 1, table: 'breadcrumb', op: 'append',
    entityId: 'trace-1',
    payload: { trace_id: 'trace-1', points: [
      { lat: 12.97, lon: 77.59, accuracy_m: 4, seq: 0, recorded_at: '2026-11-08T04:00:00.000Z' },
      { lat: 12.9701, lon: 77.5901, accuracy_m: 5, seq: 1, recorded_at: '2026-11-08T04:00:05.000Z' },
    ] },
  };
  const first = r.push({ deviceId: 'mapper-1', mapperId: 'm1', ops: [op] });
  assert.strictEqual(first.results[0].state, 'applied');
  const replay = r.push({ deviceId: 'mapper-1', mapperId: 'm1', ops: [op] });
  assert.strictEqual(replay.results[0].state, 'replayed');
  const { points } = r.listBreadcrumbs();
  assert.strictEqual(points.length, 2);
  assert.strictEqual(points[0].trace_id, 'trace-1');
});

test('breadcrumb op rejects a point without numeric coordinates', () => {
  const r = new Registry(':memory:');
  const res = r.push({
    deviceId: 'd', mapperId: 'm1',
    ops: [{ clientOpId: 'bc-bad', clientSeq: 1, table: 'breadcrumb', op: 'append',
      entityId: 't', payload: { trace_id: 't', points: [{ lat: 'x', lon: 77.5 }] } }],
  });
  assert.strictEqual(res.results[0].state, 'rejected');
});

test('listBreadcrumbs honours since', () => {
  const r = new Registry(':memory:');
  r.push({ deviceId: 'd', mapperId: 'm1', ops: [{
    clientOpId: 'bc-2', clientSeq: 1, table: 'breadcrumb', op: 'append', entityId: 't',
    payload: { trace_id: 't', points: [
      { lat: 12.97, lon: 77.59, seq: 0, recorded_at: '2026-11-08T04:00:00.000Z' },
      { lat: 12.98, lon: 77.60, seq: 1, recorded_at: '2026-11-08T05:00:00.000Z' },
    ] },
  }] });
  const { points } = r.listBreadcrumbs({ since: '2026-11-08T04:30:00.000Z' });
  assert.strictEqual(points.length, 1);
  assert.strictEqual(points[0].lat, 12.98);
});
