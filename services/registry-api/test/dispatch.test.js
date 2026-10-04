/**
 * M4 constraint tests: dispatch backend, C7 zone gating, hard blocks,
 * and the fast-signal feedback loop (PRD 6.4).
 *
 * PRD 3: the internal dispatch interface is the ONLY implemented backend. A
 * future CAD/AVL/NGO adapter would implement the same interface; nothing in the
 * core would change. These tests pin that property so it cannot drift.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { Registry } = require('../src/registry.js');
const { DispatchBackend, InternalBackend, createBackend } = require('../src/dispatch.js');
const { createServer } = require('../src/server.js');

function newRegistry() {
  const r = new Registry(':memory:');
  r.db.prepare("INSERT INTO app_user (id,email,role) VALUES ('m1','m@x','mapper')").run();
  // C4/C7: dispatch starts OFF. The pilot kill switch must be explicit.
  r.db.prepare(
    "INSERT INTO zone (code,name,lat,lon,radius_m,dispatch_enabled) VALUES " +
    "('C4','Pilot campus',12.97,77.59,600,0)",
  ).run();
  return r;
}

function enableZone(r) {
  r.db.prepare("UPDATE zone SET dispatch_enabled = 1 WHERE code = 'C4'").run();
}

async function withServer(fn, opts = {}) {
  const server = createServer(opts);
  await new Promise((res) => server.listen(0, res));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, body, role = 'dispatcher') => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-Role': role },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json() };
  };
  try { return await fn(call, server); } finally { server.close(); }
}

// ---------------------------------------------------------------------------
// PRD 3 — the backend abstraction
// ---------------------------------------------------------------------------

test('PRD 3: the interface defines exactly the four documented methods', () => {
  const b = new InternalBackend({ registry: newRegistry() });
  for (const m of ['lookup', 'dispatch', 'outcome', 'capabilities']) {
    assert.strictEqual(typeof b[m], 'function', `${m}() is part of the contract`);
  }
  // a future adapter must be able to implement the interface without editing
  // the core
  assert.ok(b instanceof DispatchBackend);
});

test('PRD 3: backend is configuration-selected, internal is the default', async () => {
  assert.ok(createBackend('internal', { registry: newRegistry() }) instanceof InternalBackend);
  assert.ok(createBackend(undefined, { registry: newRegistry() }) instanceof InternalBackend);
});

test('PRD 3: capabilities report what is NOT supported', async () => {
  const c = await new InternalBackend({ registry: newRegistry() }).capabilities();
  assert.strictEqual(c.backend, 'internal');
  assert.strictEqual(c.supportsExternalHandoff, false,
    'an external CAD/AVL handoff is out of scope and must be advertised as such');
  assert.deepStrictEqual(c.profiles, ['foot']);
});

test('the abstract base refuses every operation until implemented', async () => {
  const b = new DispatchBackend();
  await assert.rejects(() => b.lookup('x'), /not implemented/);
  await assert.rejects(() => b.capabilities(), /not implemented/);
});

// ---------------------------------------------------------------------------
// C7 — dispatch only inside the pilot mapped zone
// ---------------------------------------------------------------------------

test('C7: dispatch is refused when no zone is dispatch-enabled', async () => {
  const registry = newRegistry();
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  registry.issueCode(s, { reviewerId: 'r1' });
  // zone exists but dispatch_enabled = 0

  const b = new InternalBackend({ registry });
  const out = await b.lookup(registry.getStructure(s).code, null);
  assert.strictEqual(out.error, 'outside_mapped_zone');
  assert.strictEqual(out.http, 403);
});

test('C7: the same code routes once the zone is enabled', async () => {
  const registry = newRegistry();
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  const b = new InternalBackend({ registry });
  assert.strictEqual((await b.lookup(code, null)).error, 'outside_mapped_zone');

  enableZone(registry);
  const ok = await b.lookup(code, null);
  assert.ok(!ok.error, `expected success, got ${ok.error}`);
  assert.strictEqual(ok.zone.code, 'C4');
  assert.ok(ok.destination);
});

test('C7: a structure outside every zone stays refused even when C4 is on', async () => {
  const registry = newRegistry();
  enableZone(registry);
  // ~30 km north of the zone
  const far = registry.createStructure({ lat: 13.24, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(far, { reviewerId: 'r1' });

  const out = await new InternalBackend({ registry }).lookup(code, null);
  assert.strictEqual(out.error, 'outside_mapped_zone');
});

test('C7: occupant context is absent by default, not leaked', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  await withServer(async (call) => {
    const res = await call('POST', '/v1/dispatch/lookup', { code });
    assert.strictEqual(res.status, 200);
    // C3: the registry cannot see identity, so it cannot report any
    assert.deepStrictEqual(res.body.occupant_context, { present: false });
    const serialised = JSON.stringify(res.body);
    assert.ok(!/resident|consent|phone/i.test(serialised),
      'dispatch response must carry no identity fields');
  }, { registry });
});

// ---------------------------------------------------------------------------
// C1/C2 — hard blocks
// ---------------------------------------------------------------------------

test('C1: an unknown code and a superseded code are told apart', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const b = new InternalBackend({ registry });

  // never existed
  assert.strictEqual((await b.lookup('SLR-NOPE99', null)).error, 'structure_not_found');

  // DID exist, then was absorbed by a merge. A responder following an
  // out-of-date placard must be told it is STALE, not merely that the code is
  // unknown — those need different responses.
  const a = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const b2 = registry.createStructure({ lat: 12.97005, lon: 77.59005, status: 'surveyed' });
  const codeB = registry.issueCode(b2, { reviewerId: 'r1' });
  const cand = registry.generateDedupCandidate(b2);
  registry.decideDedup(cand, 'merge', { reviewerId: 'r1' });

  assert.ok(registry.getStructure(b2).deleted_at, 'the duplicate was soft-deleted');
  const out = await b.lookup(codeB, null);
  assert.strictEqual(out.error, 'code_superseded',
    'a merged-away code must read as stale, not unknown');
  assert.strictEqual(out.http, 404);
});

test('C2: a structure in dedup review cannot be dispatched to', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });
  registry.updateStructure(s, { status: 'disputed' });

  const out = await new InternalBackend({ registry }).lookup(code, null);
  assert.strictEqual(out.error, 'structure_in_dedup_review');
  assert.strictEqual(out.http, 409);
});

test('dispatch requires the dispatcher role over HTTP', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  await withServer(async (call) => {
    const asMapper = await call('POST', '/v1/dispatch/lookup', { code }, 'mapper');
    assert.strictEqual(asMapper.status, 403);
    const asDispatcher = await call('POST', '/v1/dispatch/lookup', { code }, 'dispatcher');
    assert.strictEqual(asDispatcher.status, 200);
  }, { registry });
});

// ---------------------------------------------------------------------------
// Fast signal — PRD 6.4
// ---------------------------------------------------------------------------

test('a failed dispatch opens a verification task ranked first', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  const b = new InternalBackend({ registry });
  const assigned = await b.dispatch(code, { responder: 'unit-7' });
  await b.outcome(assigned.dispatch_id, {
    outcome: 'failed', reason: 'gate_locked_no_responder',
    structure_id: s, actor: 'dispatch:unit-7',
  });

  const tasks = registry.openTasks();
  assert.strictEqual(tasks.length, 1);
  assert.strictEqual(tasks[0].kind, 'dispatch_failure');
  assert.strictEqual(tasks[0].signal, 'fast');
  assert.strictEqual(tasks[0].priority, 1, 'fast signal ranks first (PRD 6.4)');

  const events = registry.db.prepare('SELECT * FROM verification_event').all();
  assert.strictEqual(events.length, 1);
  assert.strictEqual(events[0].trigger_kind, 'fast');
  assert.strictEqual(events[0].source, 'dispatch_feedback');
});

test('a confirmed outcome is recorded as an observation, not a change', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  const b = new InternalBackend({ registry });
  const assigned = await b.dispatch(code, {});
  await b.outcome(assigned.dispatch_id, {
    outcome: 'confirmed', structure_id: s, actor: 'dispatch:unit-7',
    observed_geometry: { lat: 12.9701, lon: 77.5901 },
  });

  // confirmation must NOT open a re-verification task
  assert.strictEqual(registry.openTasks().length, 0);
  const events = registry.db.prepare('SELECT * FROM verification_event').all();
  assert.strictEqual(events[0].outcome, 'confirmed');
  assert.strictEqual(events[0].trigger_kind, 'fast');
});

test('C8: responder observation is the one non-inference way to overwrite ground truth', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  registry.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.97, lon: 77.59 },
    evidenceClass: 'ground_truth', source: 'mapper_survey', observedBy: 'mapper:1',
  });

  const b = new InternalBackend({ registry });
  const assigned = await b.dispatch(code, {});
  await b.outcome(assigned.dispatch_id, {
    outcome: 'confirmed', structure_id: s, actor: 'dispatch:unit-7',
  });

  // a responder observation may supersede a mapper record
  registry.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.9701, lon: 77.5901 },
    evidenceClass: 'ground_truth', source: 'dispatch_feedback',
    observedBy: 'dispatch:unit-7',
  });
  const current = registry.db.prepare(
    "SELECT observed_by FROM assertion WHERE field='centroid' AND state='asserted'").get();
  assert.strictEqual(current.observed_by, 'dispatch:unit-7');
});

// ---------------------------------------------------------------------------
// MVP flow end to end
// ---------------------------------------------------------------------------

test('MVP: Structure ID -> lookup -> assign -> outcome', async () => {
  const registry = newRegistry();
  enableZone(registry);
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  const code = registry.issueCode(s, { reviewerId: 'r1' });

  await withServer(async (call) => {
    const caps = await call('GET', '/v1/dispatch/capabilities');
    assert.strictEqual(caps.body.backend, 'internal');

    const lookup = await call('POST', '/v1/dispatch/lookup', {
      code, responder_location: { lat: 12.968, lon: 77.587 },
    });
    assert.strictEqual(lookup.status, 200);
    assert.strictEqual(lookup.body.code, code);
    assert.ok(lookup.body.destination);

    const assigned = await call('POST', '/v1/dispatch/assign',
      { code, responder: 'unit-3', structure_id: s });
    assert.ok(assigned.body.dispatch_id);

    const done = await call('POST', '/v1/dispatch/outcome', {
      dispatch_id: assigned.body.dispatch_id, outcome: 'confirmed',
      structure_id: s, actor: 'dispatch:unit-3',
    });
    assert.strictEqual(done.status, 200);

    const tasks = await call('GET', '/v1/tasks', null, 'mapper');
    assert.strictEqual(tasks.body.items.length, 0, 'a confirmed dispatch opens no task');
  }, { registry });
});
