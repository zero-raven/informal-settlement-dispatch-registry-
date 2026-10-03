/**
 * sync-core — field-level merge, outbox, cursor, idempotency.
 *
 * Implements C4 (offline operation) and C5 (opportunistic sync), and the
 * C1/C2 boundary: this module can merge FIELDS on an already-confirmed
 * structure, and it can NEVER decide entity identity. Anything touching
 * identity is escalated to the dedup queue for human review.
 *
 * Deliberately dependency-free: the same logic runs in the mapper app, in
 * tests, and in the sync service, and the CRDT merge is the part that must
 * behave identically in all three.
 */

'use strict';

// ---------------------------------------------------------------------------
// Field-level CRDT
//
// Per field: Lamport clock, with site_id as a deterministic tiebreak.
// Two mappers editing service data offline both survive; the merge is
// commutative and idempotent, so a replayed batch cannot corrupt anything.
// ---------------------------------------------------------------------------

/**
 * @typedef {{value:*, lamport:number, siteId:string}} FieldVersion
 */

const CRDT_FIELDS_BY_TABLE = {
  structure: [
    'structure_type',
    'non_residential_subtype',
    'entrance_geom',
    'entrance_independent',
    'floors_estimated',
    'material_primary',
    'occupancy_estimate',
    'is_shared_wall',
    'compound_root_id',
  ],
  structure_service: [
    'source',
    'supply_hours',
    'quality',
    'shared_with_count',
  ],
};

/**
 * Fields that must never be merged by the CRDT. Identity is a human decision.
 * Encountering one of these is a bug in the caller, not a merge case.
 */
const IDENTITY_FIELDS = new Set([
  'id',
  'code',
  'structure_id',
  'compound_root_id_is_identity',
  'version',
]);

class IdentityMergeRefused extends Error {
  constructor(field) {
    super(
      `refusing to merge identity field "${field}" (C1/C2): identity is a human decision`,
    );
    this.name = 'IdentityMergeRefused';
    this.field = field;
  }
}

/**
 * Total order on field versions. Greater wins.
 * Lamport first; siteId breaks ties deterministically so every replica
 * reaches the same answer regardless of arrival order.
 *
 * @param {FieldVersion} a
 * @param {FieldVersion} b
 * @returns {FieldVersion} the winner
 */
function mergeField(a, b) {
  if (!a) return b;
  if (!b) return a;
  if (a.lamport !== b.lamport) return a.lamport > b.lamport ? a : b;
  return a.siteId >= b.siteId ? a : b;
}

/**
 * Merge a set of per-field versions against the current local state.
 * Pure: returns a new object, never mutates its inputs.
 *
 * @param {Record<string, FieldVersion>} current
 * @param {Record<string, FieldVersion>} incoming
 * @param {{table:string}} ctx
 */
function mergeFields(current = {}, incoming = {}, ctx = {}) {
  const allowed = CRDT_FIELDS_BY_TABLE[ctx.table] || [];
  const out = { ...current };
  for (const [field, inc] of Object.entries(incoming)) {
    if (IDENTITY_FIELDS.has(field)) throw new IdentityMergeRefused(field);
    if (allowed.length && !allowed.includes(field)) {
      throw new Error(
        `field "${field}" is not CRDT-mergeable on ${ctx.table}; ` +
          `mergeable: ${allowed.join(', ')}`,
      );
    }
    out[field] = mergeField(out[field], inc);
  }
  return out;
}

/**
 * Whether a merge actually changed anything. Used to avoid pointless writes
 * and to keep the version counter meaningful.
 */
function fieldsDiffer(a = {}, b = {}) {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) {
    const x = a[k], y = b[k];
    if (!x || !y) return true;
    if (x.lamport !== y.lamport || x.siteId !== y.siteId) return true;
    if (JSON.stringify(x.value) !== JSON.stringify(y.value)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Lamport clock
// ---------------------------------------------------------------------------

class LamportClock {
  constructor(siteId, initial = 0) {
    this.siteId = siteId;
    this.counter = initial;
  }

  /** @returns {FieldVersion} */
  tick(value) {
    this.counter += 1;
    return { value, lamport: this.counter, siteId: this.siteId };
  }

  /** Absorb a remote clock so later local edits dominate what they saw. */
  observe(remote) {
    if (typeof remote === 'number' && remote > this.counter) this.counter = remote;
  }

  peek(field) {
    return { value: field?.value, lamport: this.counter, siteId: this.siteId };
  }
}

// ---------------------------------------------------------------------------
// Outbox
//
// Every write the mapper makes is queued here first. The UI never awaits the
// network (C4); sync drains this queue when connectivity appears (C5).
// ---------------------------------------------------------------------------

class Outbox {
  /**
   * @param {{deviceId:string, siteId:string}} opts
   */
  constructor({ deviceId, siteId }) {
    this.deviceId = deviceId;
    this.siteId = siteId;
    /** @type {Array<object>} */
    this.pending = [];
    this.seq = 0;
    this.clock = new LamportClock(siteId);
  }

  /**
   * Queue a write. `op` is one of create|update|delete.
   * Returns the queued op, carrying the idempotency key the server dedupes on.
   */
  enqueue(table, entityId, op, payload) {
    for (const f of Object.keys(payload?.fields ?? {})) {
      if (IDENTITY_FIELDS.has(f)) throw new IdentityMergeRefused(f);
    }
    this.seq += 1;
    const record = {
      clientOpId: `${this.siteId}-${this.seq}`,
      clientSeq: this.seq,
      table,
      entityId,
      op,
      payload,
      siteId: this.siteId,
      deviceId: this.deviceId,
      queuedAt: new Date().toISOString(),
    };
    this.pending.push(record);
    return record;
  }

  /** Ops for the next push, in client-seq order. Order matters: replaying in
   *  a different order must not change the outcome. */
  drain(limit = 50) {
    return this.pending.slice(0, limit);
  }

  /**
   * Remove ops the server acknowledged. Keyed on clientOpId so a partial
   * failure leaves the rest queued — never the whole batch.
   */
  acknowledge(opIds = []) {
    const done = new Set(opIds);
    this.pending = this.pending.filter((o) => !done.has(o.clientOpId));
    return this.pending.length;
  }

  get size() {
    return this.pending.length;
  }
}

// ---------------------------------------------------------------------------
// Idempotency ledger
//
// A dropped response must never cause a duplicate create. The client records
// the server's receipt; a replay of the same clientOpId returns it unchanged.
// ---------------------------------------------------------------------------

class IdempotencyLedger {
  constructor() {
    /** @type {Map<string, object>} */
    this.receipts = new Map();
  }

  /** Has this op already been applied? */
  seen(clientOpId) {
    return this.receipts.has(clientOpId);
  }

  record(clientOpId, receipt) {
    this.receipts.set(clientOpId, receipt);
  }

  /**
   * Process a push result, clearing acknowledged ops and folding in the
   * server's view. Returns the receipts for replays so the caller can skip
   * re-sending work the server already has.
   */
  applyPush(results = []) {
    const replays = [];
    const acked = [];
    for (const r of results) {
      if (r.state === 'replayed') {
        replays.push(r);
        acked.push(r.clientOpId);
        continue;
      }
      if (r.state === 'applied' || r.state === 'dedup_required') {
        this.record(r.clientOpId, r);
        acked.push(r.clientOpId);
      }
      // rejected / dedup_required stay visible until the caller handles them
    }
    return { replays, acked };
  }
}

// ---------------------------------------------------------------------------
// Cursor
//
// Opaque and server-authoritative. Client clocks are never trusted: a mapper
// may have been offline for days and their device clock will be wrong.
// ---------------------------------------------------------------------------

class Cursor {
  constructor(value = null) {
    this.value = value;
  }

  advance(next) {
    if (next) this.value = next;
  }

  /** Cursor to send on the next pull. */
  toQuery() {
    return this.value ? { since: this.value } : {};
  }
}

// ---------------------------------------------------------------------------
// Connectivity gate (C5)
//
// Opportunistic, never a background daemon. Nothing here retries on a timer
// or holds a socket open; sync runs when the app decides to run it.
// ---------------------------------------------------------------------------

class ConnectivityGate {
  constructor({ pull = () => true, minIntervalMs = 30000, now = () => Date.now() } = {}) {
    this.isOnline = pull();
    this.minIntervalMs = minIntervalMs;
    this.now = now;
    this.lastAttempt = 0;
  }

  /** Called when the device reports a connectivity change. */
  onChange(online) {
    this.isOnline = online;
    return online;
  }

  /**
   * May we attempt a sync right now? Debounces so a flapping connection does
   * not hammer the server, and refuses outright while offline.
   */
  shouldAttempt() {
    if (!this.isOnline) return { allowed: false, reason: 'offline' };
    const t = this.now();
    if (t - this.lastAttempt < this.minIntervalMs) {
      return { allowed: false, reason: 'debounced' };
    }
    return { allowed: true, reason: null };
  }

  markAttempt() {
    this.lastAttempt = this.now();
  }
}

module.exports = {
  CRDT_FIELDS_BY_TABLE,
  IDENTITY_FIELDS,
  IdentityMergeRefused,
  LamportClock,
  Outbox,
  IdempotencyLedger,
  Cursor,
  ConnectivityGate,
  mergeField,
  mergeFields,
  fieldsDiffer,
};