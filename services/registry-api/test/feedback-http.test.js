/**
 * C8 at the HTTP boundary.
 *
 * The engine refuses non-human principals, but a client must also be unable to
 * CLAIM to be someone else: the verifying identity is taken from the session
 * header, never from the request body.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { createServer } = require('../src/server.js');
const { FeedbackEngine } = require('../src/feedback.js');

async function withServer(fn) {
  const server = createServer();
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, body, headers = {}) => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-Role': 'mapper', ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json() };
  };
  try { return await fn(call, server); } finally { server.close(); }
}

test('a candidate can be verified over HTTP by a named mapper', async () => {
  await withServer(async (call, server) => {
    const fb = new FeedbackEngine({ registry: server.registry });
    const s = server.registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
    const c = fb.raiseCandidate({
      entityId: s, field: 'footprint', value: { shift: 3 },
      source: 'imagery_diff', producedBy: 'imagery:job-9', confidence: 0.7,
    });

    const res = await call('POST', `/v1/assertions/${c.assertionId}/verify`,
      { outcome: 'confirmed' }, { 'X-User': 'mapper:4f2a' });
    assert.strictEqual(res.status, 200, res.body);
    assert.strictEqual(res.body.state, 'confirmed');
  });
});

test('a client cannot forge the verifying identity in the body', async () => {
  await withServer(async (call, server) => {
    const fb = new FeedbackEngine({ registry: server.registry });
    const s = server.registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
    const c = fb.raiseCandidate({
      entityId: s, field: 'entrance_geom', value: {},
      source: 'imagery_diff', producedBy: 'imagery:job-9',
    });

    // no X-User header at all: there is no person to attribute this to
    const noUser = await call('POST', `/v1/assertions/${c.assertionId}/verify`,
      { outcome: 'confirmed', actor: 'mapper:forged' });
    assert.strictEqual(noUser.status, 403);
    assert.strictEqual(noUser.body.error, 'inference_cannot_verify');

    // and the candidate is still a candidate
    const still = server.registry.db
      .prepare("SELECT state FROM assertion WHERE id = ?").get(c.assertionId);
    assert.strictEqual(still.state, 'candidate');
  });
});

test('a machine identity cannot verify over HTTP either', async () => {
  await withServer(async (call, server) => {
    const fb = new FeedbackEngine({ registry: server.registry });
    const s = server.registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
    const c = fb.raiseCandidate({
      entityId: s, field: 'centroid', value: {},
      source: 'imagery_diff', producedBy: 'imagery:job-9',
    });

    for (const who of ['ml:pathgraph', 'imagery:job-9', 'system']) {
      const res = await call('POST', `/v1/assertions/${c.assertionId}/verify`,
        { outcome: 'confirmed' }, { 'X-User': who });
      assert.strictEqual(res.status, 403, `${who} must be refused`);
    }
  });
});

test('rejection over HTTP leaves ground truth untouched', async () => {
  await withServer(async (call, server) => {
    const reg = server.registry;
    reg.recordAssertion({
      entityId: reg.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' }),
      field: 'centroid', value: { lat: 12.97 },
      evidenceClass: 'ground_truth', source: 'mapper_survey', observedBy: 'mapper:1',
    });
    const s = reg.allStructures()[0];
    const fb = new FeedbackEngine({ registry: reg });
    const c = fb.raiseCandidate({
      entityId: s.id, field: 'centroid', value: { lat: 13.0 },
      source: 'imagery_diff', producedBy: 'imagery:job-9',
    });

    const res = await call('POST', `/v1/assertions/${c.assertionId}/verify`,
      { outcome: 'rejected', note: 'shadow' }, { 'X-User': 'mapper:1' });
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.body.state, 'rejected');

    const current = reg.db.prepare(
      "SELECT value FROM assertion WHERE field='centroid' AND state='asserted'").get();
    assert.deepStrictEqual(JSON.parse(current.value), { lat: 12.97 });
  });
});

test('the worklist ranks fast above slow over HTTP', async () => {
  await withServer(async (call, server) => {
    const fb = new FeedbackEngine({ registry: server.registry });
    fb.raiseTask({ kind: 'imagery_resurvey', signal: 'slow' });
    fb.raiseTask({ kind: 'dispatch_failure', signal: 'fast' });

    const res = await call('GET', '/v1/tasks');
    assert.strictEqual(res.body.items[0].signal, 'fast');
  });
});
