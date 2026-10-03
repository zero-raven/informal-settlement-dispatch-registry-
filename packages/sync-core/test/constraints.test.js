/**
 * Constraint tests for sync-core.
 *
 * These are NOT ordinary unit tests. Each one guards a PRD constraint, and
 * each is written to FAIL if the constraint is broken. They are the
 * definition of done for M1/M2.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const {
  mergeField,
  mergeFields,
  fieldsDiffer,
  LamportClock,
  Outbox,
  IdempotencyLedger,
  Cursor,
  ConnectivityGate,
  IdentityMergeRefused,
} = require('../index.js');

// ---------------------------------------------------------------------------
// C1/C2 — identity is never decided by the sync layer
// ---------------------------------------------------------------------------

test('C1/C2: merging an identity field is refused', () => {
  assert.throws(
    () => mergeFields({}, { code: { value: 'SLR-C40001', lamport: 5, siteId: 'a' } },
      { table: 'structure' }),
    IdentityMergeRefused,
  );
  assert.throws(
    () => mergeFields({}, { id: { value: 'x', lamport: 1, siteId: 'a' } },
      { table: 'structure' }),
    IdentityMergeRefused,
  );
});

test('C1/C2: the outbox refuses to queue an identity field', () => {
  const ob = new Outbox({ deviceId: 'd1', siteId: 's1' });
  assert.throws(
    () => ob.enqueue('structure', 'e1', 'create', { fields: { code: { value: 'X' } } }),
    IdentityMergeRefused,
  );
});

test('C2: two mappers merging the same field both survive deterministically', () => {
  const a = { value: 2, lamport: 7, siteId: 'mapper_a' };
  const b = { value: 3, lamport: 7, siteId: 'mapper_b' };

  // commutative: order must not change the outcome
  assert.deepStrictEqual(mergeField(a, b), mergeField(b, a));
  // deterministic tiebreak on siteId
  assert.strictEqual(mergeField(a, b).value, 3);
  assert.strictEqual(mergeField(a, b).siteId, 'mapper_b');
});

test('C2: lamport dominates siteId', () => {
  const older = { value: 'old', lamport: 3, siteId: 'zzzz' };
  const newer = { value: 'new', lamport: 9, siteId: 'aaaa' };
  assert.strictEqual(mergeField(older, newer).value, 'new');
  assert.strictEqual(mergeField(newer, older).value, 'new');
});

test('C2: a real offline two-device edit converges on one value', () => {
  // device A edits floors offline at lamport 5 (clock seeded at 4)
  const a = new LamportClock('A', 4);
  const aEdit = a.tick(3);
  // device B, never having seen A's edit, edits the same field at lamport 4
  const b = new LamportClock('B', 3);
  const bEdit = b.tick(2);

  const deviceA = mergeFields({ floors_estimated: aEdit }, {});
  const deviceB = mergeFields({}, { floors_estimated: bEdit });

  // when they meet, both land on the same value regardless of arrival order
  const conv1 = mergeFields(deviceA, deviceB);
  const conv2 = mergeFields(deviceB, deviceA);
  assert.deepStrictEqual(conv1, conv2);
  assert.strictEqual(conv1.floors_estimated.value, 3); // lamport 5 beats 4
});

test('CRDT merge is idempotent under replay', () => {
  const state = mergeFields({}, { quality: { value: 'fair', lamport: 2, siteId: 'A' } },
    { table: 'structure_service' });
  const inc = { quality: { value: 'fair', lamport: 2, siteId: 'A' } };
  const once = mergeFields(state, inc, { table: 'structure_service' });
  const twice = mergeFields(once, inc, { table: 'structure_service' });
  assert.deepStrictEqual(once, twice);
  assert.strictEqual(fieldsDiffer(once, twice), false);
});

test('a field outside the mergeable set is rejected, not silently dropped', () => {
  assert.throws(
    () => mergeFields({}, { centroid: { value: 1, lamport: 1, siteId: 'A' } },
      { table: 'structure' }),
    /not CRDT-mergeable/,
  );
});

// ---------------------------------------------------------------------------
// C5 — opportunistic sync
// ---------------------------------------------------------------------------

test('C5: nothing is attempted while offline', () => {
  let now = 1000000;
  const gate = new ConnectivityGate({ pull: () => false, now: () => now });
  assert.deepStrictEqual(gate.shouldAttempt(), { allowed: false, reason: 'offline' });
});

test('C5: a flapping connection is debounced, not hammered', () => {
  let now = 1000000;
  const gate = new ConnectivityGate({ pull: () => true, minIntervalMs: 30000, now: () => now });
  assert.strictEqual(gate.shouldAttempt().allowed, true);
  gate.markAttempt();
  assert.strictEqual(gate.shouldAttempt().allowed, false); // debounced
  now += 31000;
  assert.strictEqual(gate.shouldAttempt().allowed, true); // window elapsed
});

test('C5: reconnection unblocks sync without a restart', () => {
  let online = false;
  let now = 1000000;
  const gate = new ConnectivityGate({ pull: () => online, now: () => now });
  assert.strictEqual(gate.shouldAttempt().allowed, false);
  gate.markAttempt();
  now += 31000; // past the debounce window, so reconnect is the only variable
  assert.strictEqual(gate.shouldAttempt().allowed, false); // still offline
  online = true;
  gate.onChange(true);
  assert.strictEqual(gate.shouldAttempt().allowed, true);
});

// ---------------------------------------------------------------------------
// C4/C5 — outbox and idempotency
// ---------------------------------------------------------------------------

test('outbox preserves client order and never mutates the drained batch', () => {
  const ob = new Outbox({ deviceId: 'd1', siteId: 's1' });
  ob.enqueue('structure', 'e1', 'create', { fields: {} });
  ob.enqueue('structure', 'e2', 'update', { fields: {} });
  const batch = ob.drain();
  assert.strictEqual(batch.length, 2);
  assert.ok(batch[0].clientSeq < batch[1].clientSeq);
  ob.acknowledge([batch[0].clientOpId]);
  assert.strictEqual(ob.size, 1);
  // draining twice without acknowledging returns the same op twice
  assert.strictEqual(ob.drain()[0].clientOpId, batch[1].clientOpId);
});

test('a partial failure leaves the rest of the batch queued', () => {
  const ob = new Outbox({ deviceId: 'd1', siteId: 's1' });
  const a = ob.enqueue('structure', 'e1', 'create', { fields: {} });
  const b = ob.enqueue('structure', 'e2', 'create', { fields: {} });
  ob.acknowledge([a.clientOpId]); // only the first succeeded
  assert.strictEqual(ob.size, 1);
  assert.strictEqual(ob.pending[0].clientOpId, b.clientOpId);
});

test('C4: replaying the same batch ten times yields identical receipts', () => {
  const ob = new Outbox({ deviceId: 'd1', siteId: 's1' });
  const op = ob.enqueue('structure', 'e1', 'create', { fields: { quality: 1 } });

  // server replies twice for the same clientOpId
  const ledger = new IdempotencyLedger();
  ledger.record(op.clientOpId, { serverId: 'srv-1', version: 1 });

  for (let i = 0; i < 10; i++) {
    const { replays } = ledger.applyPush([
      { clientOpId: op.clientOpId, state: 'replayed', serverId: 'srv-1', version: 1 },
    ]);
    assert.strictEqual(replays.length, 1);
    assert.strictEqual(replays[0].serverId, 'srv-1');
  }
  // exactly one server entity exists; no duplicate create
  assert.strictEqual(ledger.receipts.size, 1);
});

test('a dedup_required result is acknowledged but stays visible', () => {
  const ledger = new IdempotencyLedger();
  const { acked } = ledger.applyPush([
    { clientOpId: 'op-1', state: 'dedup_required', dedupCandidateId: 'c1' },
  ]);
  assert.deepStrictEqual(acked, ['op-1']);
  // the receipt records that a human must review; it is not an auto-merge
  assert.strictEqual(ledger.receipts.get('op-1').dedupCandidateId, 'c1');
});

test('a rejected op is not acknowledged and not recorded', () => {
  const ledger = new IdempotencyLedger();
  const { acked } = ledger.applyPush([
    { clientOpId: 'op-2', state: 'rejected', reason: 'structure_in_dedup_review' },
  ]);
  assert.strictEqual(acked.length, 0);
  assert.strictEqual(ledger.seen('op-2'), false);
});

// ---------------------------------------------------------------------------
// Cursor — server-authoritative, opaque
// ---------------------------------------------------------------------------

test('the cursor advances only forward and never invents a value', () => {
  const c = new Cursor();
  assert.deepStrictEqual(c.toQuery(), {});
  c.advance('srv:2026-03-20T07:59:12Z:99341');
  assert.deepStrictEqual(c.toQuery(), { since: 'srv:2026-03-20T07:59:12Z:99341' });
  c.advance(null); // a page with no next cursor must not clear it
  assert.ok(c.value, 'cursor must survive a null advance');
});