/**
 * Live HTTP end-to-end: the documented contract, actually executed.
 *
 * Walks the whole M2 journey over a real socket the way the mapper app does —
 * push, dedup review, decision, code issuance, QR.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { createServer } = require('../src/server.js');

async function withServer(fn) {
  const server = createServer();
  await new Promise((r) => server.listen(0, r));
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const call = async (method, path, body, role = 'mapper') => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-Role': role },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json() };
  };
  try { return await fn(call, base); } finally { server.close(); }
}

test('HTTP: full journey over a real socket', async () => {
  await withServer(async (call) => {
    // 1. a mapper pushes an offline batch
    const push = await call('POST', '/v1/sync/push', {
      device_id: 'dev1',
      ops: [
        { clientOpId: 'a1', clientSeq: 1, table: 'local_structure', op: 'create',
          payload: { centroid: { lat: 12.97, lon: 77.59 }, structure_type: 'standalone_dwelling',
                     entrance_geom: { lat: 12.97, lon: 77.59 }, entrance_independent: true } },
        { clientOpId: 'a2', clientSeq: 2, table: 'local_structure', op: 'create',
          payload: { centroid: { lat: 12.9800, lon: 77.60 }, structure_type: 'shared_wall_dwelling',
                     entrance_geom: { lat: 12.9800, lon: 77.60 }, entrance_independent: true } },
      ],
    });
    assert.strictEqual(push.status, 200);
    assert.ok(push.body.results.every((r) => r.state === 'applied'));
    const firstId = push.body.results[0].serverId;

    // 2. replay is idempotent
    const replay = await call('POST', '/v1/sync/push', {
      device_id: 'dev1',
      ops: [{ clientOpId: 'a1', clientSeq: 1, table: 'local_structure', op: 'create',
              payload: { centroid: { lat: 12.97, lon: 77.59 } } }],
    });
    assert.strictEqual(replay.body.results[0].state, 'replayed');

    // 3. a second mapper captures the same building -> dedup_required
    const dup = await call('POST', '/v1/sync/push', {
      device_id: 'dev2',
      ops: [{ clientOpId: 'b1', clientSeq: 1, table: 'local_structure', op: 'create',
              payload: { centroid: { lat: 12.97005, lon: 77.59005 },
                         structure_type: 'standalone_dwelling',
                         entrance_geom: { lat: 12.97005, lon: 77.59005 },
                         entrance_independent: true } }],
    });
    assert.strictEqual(dup.body.results[0].state, 'dedup_required');

    // 4. the dedup queue is reviewer-only
    const forbidden = await call('GET', '/v1/dedup', null, 'mapper');
    assert.strictEqual(forbidden.status, 403);
    const queue = await call('GET', '/v1/dedup', null, 'reviewer');
    assert.strictEqual(queue.status, 200);
    assert.strictEqual(queue.body.items.length, 1);

    // 5. a mapper cannot decide
    const badDecision = await call('POST',
      `/v1/dedup/${queue.body.items[0].id}/decision`, { decision: 'merge' }, 'mapper');
    assert.strictEqual(badDecision.status, 403, 'C2: only a reviewer may decide');

    // 6. the reviewer merges -> one code on the survivor
    const decision = await call('POST',
      `/v1/dedup/${queue.body.items[0].id}/decision`,
      { decision: 'merge', note: 'same unit re-surveyed' }, 'reviewer');
    assert.strictEqual(decision.status, 200);
    assert.ok(decision.body.code, 'the survivor is coded by the decision');

    // 7. the code resolves, and its QR renders
    const code = decision.body.code;
    const got = await call('GET', `/v1/structures/${code}`);
    assert.strictEqual(got.status, 200);
    assert.strictEqual(got.body.code, code);

    const qr = await call('GET', `/v1/structures/${code}/qr`);
    assert.strictEqual(qr.status, 200);
    // A QR encodes to a bitmap, so the code is NOT literal SVG text; it is
    // carried by `payload` and rendered as path data.
    assert.ok(qr.body.svg.startsWith('<svg'));
    assert.ok(qr.body.payload.includes(code), 'the payload carries the code');
    assert.match(qr.body.svg_sha256, /^[0-9a-f]{64}$/);

    // 8. the merged-away structure's placard says SUPERSEDED, not "unknown"
    const stale = await call('GET', `/v1/structures/${dup.body.results[0].serverId ? 'SLR-NOPE00' : 'x'}/qr`);
    assert.strictEqual(stale.status, 404);
    assert.ok(['structure_not_found', 'code_superseded'].includes(stale.body.error));

    // 9. bootstrap carries no identity data
    const boot = await call('GET', '/v1/sync/bootstrap?zone=C4');
    assert.strictEqual(boot.status, 200);
    for (const s of boot.body.structures) {
      assert.ok(!('resident' in s) && !('consent' in s));
    }

    // 10. health reports the open review queue
    const health = await call('GET', '/v1/sync/health');
    assert.strictEqual(health.status, 200);
    assert.strictEqual(health.body.dedup_open, 0, 'queue is empty after the decision');
    assert.strictEqual(health.body.structures, 2, 'the duplicate was soft-deleted');
  });
});

test('HTTP: an unknown structure is 404 with a structured error', async () => {
  await withServer(async (call) => {
    const r = await call('GET', '/v1/structures/SLR-Z99999');
    assert.strictEqual(r.status, 404);
    assert.strictEqual(r.body.error, 'structure_not_found');
  });
});