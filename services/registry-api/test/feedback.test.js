/**
 * M5 constraint tests: the two-speed queue (PRD 6.4) and the C8 pipeline.
 *
 * C8 is the spine: Inference -> Candidate -> Verification -> Ground-truth
 * update. These tests assert that a machine can never take the third step.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { Registry } = require('../src/registry.js');
const { FeedbackEngine, defaultPromoter } = require('../src/feedback.js');

function fixture() {
  const registry = new Registry(':memory:');
  registry.db.prepare(
    "INSERT INTO app_user (id,email,role) VALUES ('m1','m@x','mapper')",
  ).run();
  const s = registry.createStructure({ lat: 12.97, lon: 77.59, status: 'surveyed' });
  return { registry, s, fb: new FeedbackEngine({ registry }) };
}

// ---------------------------------------------------------------------------
// Two-speed model — PRD 6.4
// ---------------------------------------------------------------------------

test('fast-signal work always outranks slow-signal work', () => {
  const { fb } = fixture();
  fb.raiseTask({ kind: 'imagery_resurvey', signal: 'slow', note: 'weeks away' });
  fb.raiseTask({ kind: 'dispatch_failure', signal: 'fast', note: 'responder blocked' });

  const list = fb.worklist();
  assert.strictEqual(list.length, 2);
  assert.strictEqual(list[0].signal, 'fast', 'a blocked responder outranks an imagery pixel');
  assert.strictEqual(list[1].signal, 'slow');
});

test('a low-priority fast task still outranks a high-priority slow one', () => {
  const { fb } = fixture();
  // deliberately inverted priorities: rank must dominate, not the priority field
  fb.raiseTask({ kind: 'imagery_resurvey', signal: 'slow', priority: 1 });
  fb.raiseTask({ kind: 'dispatch_failure', signal: 'fast', priority: 99 });
  assert.strictEqual(fb.worklist()[0].signal, 'fast');
});

test('a failed dispatch opens a fast task, a confirmed one opens none', () => {
  const { fb } = fixture();
  fb.raiseTask({ kind: 'dispatch_failure', signal: 'fast' });
  assert.strictEqual(fb.worklist().length, 1);
  fb.completeTask({ taskId: fb.worklist()[0].id, outcome: 'confirmed', actor: 'mapper:1' });
  assert.strictEqual(fb.worklist().length, 0);
});

test('an unknown signal is refused rather than defaulted', () => {
  const { fb } = fixture();
  assert.throws(() => fb.raiseTask({ kind: 'x', signal: 'whenever' }), /unknown signal/);
});

// ---------------------------------------------------------------------------
// C8 — inference can only ever be a candidate
// ---------------------------------------------------------------------------

test('an inference output is recorded as a candidate, never as ground truth', () => {
  const { registry, s, fb } = fixture();
  const out = fb.raiseCandidate({
    entityId: s, field: 'footprint', value: { shift: 3 },
    source: 'imagery_diff', producedBy: 'imagery:job-9', confidence: 0.71,
    reason: 'imagery diff suggests a shift',
  });
  assert.strictEqual(out.state, 'candidate');

  const rows = registry.db.prepare('SELECT * FROM assertion').all();
  assert.strictEqual(rows.length, 1);
  assert.strictEqual(rows[0].evidence_class, 'inference');
  assert.strictEqual(rows[0].state, 'candidate');
  assert.strictEqual(rows[0].observed_by, null, 'inference has no observer');
  assert.strictEqual(rows[0].confidence, 0.71);

  // and it opened slow-signal work
  assert.strictEqual(fb.worklist()[0].signal, 'slow');
});

test('raising a candidate never disturbs the existing ground truth', () => {
  const { registry, s, fb } = fixture();
  registry.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.97 },
    evidenceClass: 'ground_truth', source: 'mapper_survey', observedBy: 'mapper:1',
  });
  fb.raiseCandidate({
    entityId: s, field: 'centroid', value: { lat: 13.0 },
    source: 'imagery_diff', producedBy: 'imagery:job-9', confidence: 0.9,
  });
  const current = registry.db.prepare(
    "SELECT value, evidence_class FROM assertion WHERE field='centroid' AND state='asserted'",
  ).get();
  assert.deepStrictEqual(JSON.parse(current.value), { lat: 12.97 });
  assert.strictEqual(current.evidence_class, 'ground_truth');
});

// ---------------------------------------------------------------------------
// C8 — only a human may promote
// ---------------------------------------------------------------------------

test('a non-human principal cannot verify a candidate', () => {
  const { s, fb } = fixture();
  const c = fb.raiseCandidate({
    entityId: s, field: 'footprint', value: { shift: 3 },
    source: 'imagery_diff', producedBy: 'imagery:job-9',
  });
  for (const actor of ['ml:pathgraph', 'imagery:job-9', 'system', 'change-detector:worker']) {
    assert.throws(
      () => fb.verify({ assertionId: c.assertionId, outcome: 'confirmed', actor }),
      /not a human principal/,
      `${actor} must not be able to promote a candidate`,
    );
  }
});

test('every human role CAN verify', () => {
  for (const actor of ['mapper:4f2a', 'dispatch:unit-7', 'reviewer:r1', 'admin:a1', 'resident:hash9']) {
    assert.strictEqual(defaultPromoter(actor), true, `${actor} is a human principal`);
  }
});

test('verification writes ground truth and supersedes the prior value', () => {
  const { registry, s, fb } = fixture();
  registry.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.97 },
    evidenceClass: 'ground_truth', source: 'mapper_survey', observedBy: 'mapper:1',
  });
  const c = fb.raiseCandidate({
    entityId: s, field: 'centroid', value: { lat: 13.0 },
    source: 'imagery_diff', producedBy: 'imagery:job-9', confidence: 0.8,
  });

  const out = fb.verify({
    assertionId: c.assertionId, outcome: 'confirmed',
    value: { lat: 12.98 }, actor: 'mapper:4f2a', note: 'walked it',
  });
  assert.strictEqual(out.state, 'confirmed');

  const current = registry.db.prepare(
    "SELECT value, observed_by, evidence_class FROM assertion WHERE field='centroid' AND state='asserted'",
  ).get();
  assert.deepStrictEqual(JSON.parse(current.value), { lat: 12.98 });
  assert.strictEqual(current.observed_by, 'mapper:4f2a');
  assert.strictEqual(current.evidence_class, 'ground_truth');

  // the prior ground truth is superseded, not deleted
  const prior = registry.db.prepare(
    "SELECT COUNT(*) AS n FROM assertion WHERE field='centroid' AND state='superseded'",
  ).get();
  assert.strictEqual(prior.n, 1);
});

// ---------------------------------------------------------------------------
// Rejection is a first-class outcome
// ---------------------------------------------------------------------------

test('rejecting a candidate leaves ground truth completely untouched', () => {
  const { registry, s, fb } = fixture();
  registry.recordAssertion({
    entityId: s, field: 'centroid', value: { lat: 12.97 },
    evidenceClass: 'ground_truth', source: 'mapper_survey', observedBy: 'mapper:1',
  });
  const c = fb.raiseCandidate({
    entityId: s, field: 'centroid', value: { lat: 13.0 },
    source: 'imagery_diff', producedBy: 'imagery:job-9', confidence: 0.8,
  });

  const out = fb.verify({
    assertionId: c.assertionId, outcome: 'rejected',
    actor: 'mapper:4f2a', note: 'shadow, not a real change',
  });
  assert.strictEqual(out.state, 'rejected');
  assert.strictEqual(out.groundTruthUnchanged, true);

  const current = registry.db.prepare(
    "SELECT value, observed_by FROM assertion WHERE field='centroid' AND state='asserted'",
  ).get();
  assert.deepStrictEqual(JSON.parse(current.value), { lat: 12.97 },
    'rejecting a candidate must never clear the existing value');
  assert.strictEqual(current.observed_by, 'mapper:1');
});

test('a rejected candidate closes its task', () => {
  const { s, fb } = fixture();
  const c = fb.raiseCandidate({
    entityId: s, field: 'footprint', value: {},
    source: 'imagery_diff', producedBy: 'imagery:job-9',
  });
  assert.strictEqual(fb.worklist().length, 1);
  fb.verify({ assertionId: c.assertionId, outcome: 'rejected', actor: 'mapper:1' });
  assert.strictEqual(fb.worklist().length, 0);
});

test('most candidates being rejected is reportable, not an error', () => {
  const { s, fb } = fixture();
  for (let i = 0; i < 8; i++) {
    const c = fb.raiseCandidate({
      entityId: s, field: `footprint_${i}`, value: { i },
      source: 'imagery_diff', producedBy: 'imagery:job-9',
    });
    fb.verify({ assertionId: c.assertionId, outcome: 'rejected', actor: 'mapper:1' });
  }
  const c = fb.raiseCandidate({
    entityId: s, field: 'entrance_geom', value: { moved: true },
    source: 'imagery_diff', producedBy: 'imagery:job-9',
  });
  fb.verify({ assertionId: c.assertionId, outcome: 'confirmed', actor: 'mapper:1' });

  const st = fb.stats();
  assert.strictEqual(st.rejected, 8);
  assert.strictEqual(st.completed, 9);
  assert.strictEqual(st.conversion_rate, 0.1111,
    'conversion rate is a result to report, not a failure to hide');
});

// ---------------------------------------------------------------------------
// Task lifecycle
// ---------------------------------------------------------------------------

test('completing a task without a candidate is still an observation', () => {
  const { registry, s, fb } = fixture();
  const { taskId } = fb.raiseTask({ structureId: s, kind: 'imagery_resurvey', signal: 'slow' });
  const out = fb.completeTask({
    taskId, outcome: 'confirmed', actor: 'mapper:9c1d',
    updates: { entrance_geom: { lat: 12.9701, lon: 77.5901 } },
  });
  assert.strictEqual(out.updatesApplied, 1);
  const a = registry.db.prepare(
    "SELECT evidence_class, observed_by FROM assertion WHERE field='entrance_geom'").get();
  assert.strictEqual(a.evidence_class, 'ground_truth');
  assert.strictEqual(a.observed_by, 'mapper:9c1d');
});

test('a non-human principal cannot complete a task', () => {
  const { s, fb } = fixture();
  const { taskId } = fb.raiseTask({ structureId: s, kind: 'imagery_resurvey', signal: 'slow' });
  assert.throws(
    () => fb.completeTask({ taskId, actor: 'ml:graph' }),
    /non-human principal cannot complete a task/,
  );
});

test('deferring decides nothing', () => {
  const { registry, s, fb } = fixture();
  const { taskId } = fb.raiseTask({ structureId: s, kind: 'imagery_resurvey', signal: 'slow' });
  const out = fb.deferTask({ taskId, actor: 'mapper:1', note: 'could not tell' });
  assert.strictEqual(out.state, 'deferred');
  assert.strictEqual(registry.db.prepare('SELECT COUNT(*) AS n FROM assertion').get().n, 0,
    'deferring must not create or change any assertion');
});

test('every verification is written to the audit trail', () => {
  const { registry, s, fb } = fixture();
  const c = fb.raiseCandidate({
    entityId: s, field: 'footprint', value: {},
    source: 'imagery_diff', producedBy: 'imagery:job-9',
  });
  fb.verify({ assertionId: c.assertionId, outcome: 'rejected', actor: 'mapper:1', note: 'shadow' });
  const ev = registry.db.prepare('SELECT * FROM verification_event').all();
  assert.ok(ev.length >= 1);
  assert.ok(ev.some((e) => e.actor === 'mapper:1'), 'the verifying person is recorded');
});

// ---------------------------------------------------------------------------
// The pending-candidate worklist spans every inference source
// ---------------------------------------------------------------------------

test('pendingCandidates spans every inference source, filterable by type', () => {
  const { s, fb } = fixture();
  fb.raiseCandidate({ entityId: s, field: 'footprint', value: {}, source: 'imagery_diff',
                      producedBy: 'imagery:job-9' });
  fb.raiseCandidate({ entityId: s, field: 'centroid', value: {}, source: 'dedup_review',
                      producedBy: 'ml:dedup' });
  fb.raiseCandidate({ entityId: s, field: 'centroid', value: {}, source: 'footprint_bootstrap',
                      producedBy: 'ml:bootstrap' });

  assert.strictEqual(fb.pendingCandidates().length, 3);
  assert.strictEqual(fb.pendingCandidates({ type: 'imagery_diff' }).length, 1);
});

test('a confirmed candidate leaves the pending worklist', () => {
  const { s, fb } = fixture();
  const c = fb.raiseCandidate({ entityId: s, field: 'footprint', value: {},
                                source: 'imagery_diff', producedBy: 'imagery:job-9' });
  assert.strictEqual(fb.pendingCandidates().length, 1);
  fb.verify({ assertionId: c.assertionId, outcome: 'confirmed', actor: 'mapper:1' });
  assert.strictEqual(fb.pendingCandidates().length, 0);
});
