/**
 * registry-api — structural registry.
 *
 * Holds NO resident PII and has no credential capable of reaching identity_db
 * (C3). Identity is bridged only by consent-api's audited resolver.
 *
 * M2 scope: synchronisation, dedup review, code issuance, QR.
 * Identity rules enforced here:
 *   C1  a code is issued ONLY inside a human dedup decision
 *   C2  no automated merge path exists
 *   C8  inference never overwrites ground truth
 */

'use strict';

const { DatabaseSync } = require('node:sqlite');
const crypto = require('node:crypto');

// ---------------------------------------------------------------------------
// Field-level CRDT — server side. Mirrors packages/sync-core exactly; the two
// must agree, so both are tested against the same properties.
// ---------------------------------------------------------------------------

/** Fields that may be merged automatically. Everything else needs a human. */
const MERGEABLE = {
  structure: [
    'structure_type', 'non_residential_subtype', 'entrance_geom',
    'entrance_independent', 'floors_estimated', 'material_primary',
    'occupancy_estimate', 'is_shared_wall',
  ],
  structure_service: ['source', 'supply_hours', 'quality', 'shared_with_count'],
};

/** Never merged by a machine. C1/C2. */
const IDENTITY_FIELDS = new Set(['id', 'code', 'version', 'created_by']);

class IdentityMergeRefused extends Error {
  constructor(field) {
    super(`refusing to merge identity field "${field}" (C1/C2)`);
    this.name = 'IdentityMergeRefused';
    this.field = field;
  }
}

function mergeField(a, b) {
  if (!a) return b;
  if (!b) return a;
  if (a.lamport !== b.lamport) return a.lamport > b.lamport ? a : b;
  return a.siteId >= b.siteId ? a : b;
}

function mergeFields(current = {}, incoming = {}, table = 'structure') {
  const allowed = MERGEABLE[table] || [];
  const out = { ...current };
  for (const [field, inc] of Object.entries(incoming)) {
    if (IDENTITY_FIELDS.has(field)) throw new IdentityMergeRefused(field);
    if (allowed.length && !allowed.includes(field)) {
      throw new Error(`field "${field}" is not mergeable on ${table}`);
    }
    out[field] = mergeField(out[field], inc);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

class Registry {
  /** @param {string} dbPath ':memory:' or a file */
  constructor(dbPath = ':memory:') {
    this.db = new DatabaseSync(dbPath);
    this.db.exec('PRAGMA foreign_keys = ON');
    this.applySchema();
  }

  /** Mirrors services/registry-api/migrations/000_init.sql. */
  applySchema() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS app_user (
        id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, role TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS structure (
        id TEXT PRIMARY KEY,
        code TEXT UNIQUE,
        status TEXT NOT NULL DEFAULT 'candidate',
        structure_type TEXT NOT NULL DEFAULT 'standalone_dwelling',
        non_residential_subtype TEXT,
        lat REAL NOT NULL, lon REAL NOT NULL,
        entrance_lat REAL, entrance_lon REAL,
        entrance_independent INTEGER,
        is_shared_wall INTEGER NOT NULL DEFAULT 0,
        shares_wall_with TEXT REFERENCES structure(id),
        compound_root_id TEXT REFERENCES structure(id),
        floors_estimated INTEGER, material_primary TEXT, occupancy_estimate INTEGER,
        disclosure_policy TEXT NOT NULL DEFAULT 'aggregate_only',
        dedup_threshold_m REAL NOT NULL DEFAULT 12.0,
        last_verified_at TEXT, verification_src TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        created_by TEXT NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        deleted_at TEXT
      );
      CREATE TABLE IF NOT EXISTS structure_service (
        id TEXT PRIMARY KEY, structure_id TEXT NOT NULL REFERENCES structure(id),
        service_type TEXT NOT NULL, source TEXT, supply_hours TEXT,
        quality TEXT, shared_with_count INTEGER NOT NULL DEFAULT 0,
        last_verified_at TEXT, still_true_checked_at TEXT,
        field_version INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL,
        UNIQUE (structure_id, service_type)
      );
      CREATE TABLE IF NOT EXISTS dedup_candidate (
        id TEXT PRIMARY KEY,
        structure_a TEXT NOT NULL REFERENCES structure(id),
        structure_b TEXT NOT NULL REFERENCES structure(id),
        distance_m REAL NOT NULL, entrance_dist_m REAL, iou REAL,
        wall_shared INTEGER NOT NULL DEFAULT 0, photo_similarity REAL,
        mapper_conflict INTEGER NOT NULL DEFAULT 0,
        score REAL NOT NULL, signals TEXT NOT NULL DEFAULT '{}',
        state TEXT NOT NULL DEFAULT 'open',
        reviewer_id TEXT, reviewed_at TEXT, decision_note TEXT,
        created_at TEXT NOT NULL,
        CHECK (structure_a <> structure_b)
      );
      CREATE TABLE IF NOT EXISTS assertion (
        id TEXT PRIMARY KEY,
        entity_table TEXT NOT NULL, entity_id TEXT NOT NULL, field TEXT NOT NULL,
        value TEXT NOT NULL, evidence_class TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'asserted',
        source TEXT NOT NULL, observed_by TEXT, observed_at TEXT,
        produced_by TEXT, produced_at TEXT, confidence REAL,
        supersedes_id TEXT, created_at TEXT NOT NULL
      );
      -- Only an ASSERTED row is the current value. A rejected candidate is a
      -- terminal state, not a value: it must never satisfy uniqueness, or a
      -- rejected candidate would block a later legitimate assertion.
      CREATE UNIQUE INDEX IF NOT EXISTS assertion_current
        ON assertion (entity_table, entity_id, field) WHERE state = 'asserted';
      CREATE TABLE IF NOT EXISTS sync_receipt (
        client_op_id TEXT PRIMARY KEY, client_seq INTEGER NOT NULL, mapper_id TEXT NOT NULL,
        entity_table TEXT NOT NULL, entity_id TEXT NOT NULL,
        server_version INTEGER NOT NULL, received_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS structure_code_sequence (
        bucket INTEGER PRIMARY KEY, next_value INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS zone (
        id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL, lat REAL, lon REAL, radius_m REAL,
        dispatch_enabled INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS task (
        id TEXT PRIMARY KEY,
        structure_id TEXT REFERENCES structure(id),
        zone TEXT, kind TEXT NOT NULL, signal TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 5,
        state TEXT NOT NULL DEFAULT 'open',
        assignee TEXT, note TEXT, outcome TEXT,
        payload_json TEXT,
        completed_at TEXT,
        created_at TEXT NOT NULL
      );
      -- PRD 6.6 aggregate reporting view. Projects NO per-structure column,
      -- so a reporting consumer cannot iterate its way back to individuals.
      -- The in-memory mirror must carry it or the leak check cannot run.
      CREATE VIEW IF NOT EXISTS v_zone_service_stats AS
      SELECT z.code          AS zone_code,
             count(DISTINCT s.id) AS structures_counted,
             sv.service_type,
             count(*) FILTER (WHERE sv.source NOT IN ('none','unknown')) AS connected_count,
             -- SQLite has no round(x, n) and no ::real; the shipped view uses
             -- Postgres syntax in 000_init.sql. The mirror only needs the
             -- COLUMN SHAPE for the PRD 6.6 leak check.
             cast(count(*) FILTER (WHERE sv.source NOT IN ('none','unknown')) as real)
               / max(count(*), 1) AS share
      FROM zone z
      JOIN structure s ON abs(s.lat - z.lat) <= 0.002
                       AND abs(s.lon - z.lon) <= 0.002
      LEFT JOIN structure_service sv ON sv.structure_id = s.id
      WHERE s.deleted_at IS NULL
      GROUP BY z.code, sv.service_type;

      CREATE TABLE IF NOT EXISTS verification_event (
        -- NULL for zone-level work (a whole re-survey, not one structure)
        id INTEGER PRIMARY KEY AUTOINCREMENT, structure_id TEXT,
        trigger_kind TEXT NOT NULL, source TEXT NOT NULL, outcome TEXT,
        payload TEXT, actor TEXT NOT NULL, created_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS dispatcher_responders (
        dispatch_id TEXT PRIMARY KEY,
        code TEXT NOT NULL,
        responder TEXT,
        at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS dispatcher_outcomes (
        dispatch_id TEXT PRIMARY KEY,
        outcome TEXT NOT NULL,
        structure_id TEXT,
        actor TEXT,
        at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS field_version (
        entity_id TEXT NOT NULL, field TEXT NOT NULL,
        lamport INTEGER NOT NULL, site_id TEXT NOT NULL,
        PRIMARY KEY (entity_id, field)
      );
    `);
  }

  // ------------------------------------------------------------- idempotency

  /** Replaying the same clientOpId must never duplicate. Returns a prior receipt. */
  receipt(clientOpId) {
    return this.db
      .prepare('SELECT * FROM sync_receipt WHERE client_op_id = ?')
      .get(clientOpId);
  }

  recordReceipt(r) {
    this.db.prepare(`
      INSERT INTO sync_receipt
        (client_op_id, client_seq, mapper_id, entity_table, entity_id, server_version, received_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(client_op_id) DO NOTHING
    `).run(r.clientOpId, r.clientSeq, r.mapperId, r.table, r.entityId,
      r.serverVersion, new Date().toISOString());
  }

  // ------------------------------------------------------- dedup (multi-signal)

  /**
   * Generate a dedup candidate when a new pin sits inside another structure's
   * candidate-generation threshold.
   *
   * PRD 6.1: proximity ALONE never decides. Six independent signals are
   * recorded so a human reviews evidence rather than a radius verdict. A single
   * radius cannot express "shares a wall but separate entrances".
   *
   * @returns the candidate id, or null when nothing is near enough
   */
  generateDedupCandidate(newId, thresholdM = 12.0) {
    const s = this.getStructure(newId);
    if (!s) return null;

    const rows = this.db.prepare(`
      SELECT id, lat, lon, entrance_lat, entrance_lon, is_shared_wall
      FROM structure
      WHERE deleted_at IS NULL AND id <> ?
        AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
    `).all(newId,
      s.lat - thresholdM / 111320, s.lat + thresholdM / 111320,
      s.lon - thresholdM / (111320 * Math.cos(s.lat * Math.PI / 180)),
      s.lon + thresholdM / (111320 * Math.cos(s.lat * Math.PI / 180)));

    let best = null;
    for (const r of rows) {
      const distance = haversine(s.lat, s.lon, r.lat, r.lon);
      if (distance > thresholdM) continue;

      const entranceDist =
        s.entrance_lat != null && r.entrance_lat != null
          ? haversine(s.entrance_lat, s.entrance_lon, r.entrance_lat, r.entrance_lon)
          : null;
      const wallShared = !!(s.is_shared_wall && r.is_shared_wall);

      const signals = {
        distance_m: round(distance),
        entrance_dist_m: entranceDist == null ? null : round(entranceDist),
        wall_shared: wallShared,
        // same mapper capturing both and asserting one unit is the strongest
        // single signal a human gets
        mapper_conflict: false,
        photo_similarity: null,
        iou: null,
      };

      // RANKING ONLY. Never a decision.
      const score = scoreSignals(signals);
      if (!best || score > best.score) best = { other: r, signals, score, distance };
    }
    if (!best) return null;

    const id = crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO dedup_candidate
        (id, structure_a, structure_b, distance_m, entrance_dist_m, wall_shared,
         score, signals, state, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)
    `).run(id, best.other.id, newId, best.signals.distance_m,
      best.signals.entrance_dist_m, best.signals.wall_shared ? 1 : 0,
      best.score, JSON.stringify(best.signals), new Date().toISOString());
    return id;
  }

  openDedupQueue(state = 'open') {
    return this.db
      .prepare('SELECT * FROM dedup_candidate WHERE state = ? ORDER BY score DESC')
      .all(state);
  }

  /**
   * The ONLY place a code is ever issued (C1).
   *
   * Called exclusively from a reviewer decision. There is no endpoint or code
   * path that issues a code without one.
   */
  issueCode(structureId, { reviewerId, zoneCode = 'C' } = {}) {
    // A code is issued ONLY inside a human decision. If no reviewer is named,
    // this call is by definition not a human decision — refuse rather than
    // default, because defaulting here would be the C1 hole.
    if (!reviewerId) {
      throw new Error(
        `code issuance requires a reviewer (C1): refusing to issue a code for ${structureId}`);
    }
    const s = this.getStructure(structureId);
    if (!s) throw new Error(`no such structure ${structureId}`);
    // Mirrors trg_structure_code_requires_prior_survey: the survey must already
    // have happened, so an automated caller cannot mint identity.
    if (!['surveyed', 'verified', 'demolished', 'unreachable'].includes(s.status)) {
      throw new Error(
        `code cannot be issued to a ${s.status} structure — a human dedup decision is required`);
    }
    if (s.code) return s.code;

    const code = this.#nextCode(zoneCode);
    this.db.prepare('UPDATE structure SET code = ?, version = version + 1 WHERE id = ?')
      .run(code, structureId);
    return code;
  }

  /** Opaque and non-derivable: no coordinates, no geohash, no position hash. */
  #nextCode(zoneLetter) {
    let row = this.db.prepare('SELECT bucket, next_value FROM structure_code_sequence WHERE bucket = 1').get();
    if (!row) {
      this.db.prepare('INSERT INTO structure_code_sequence (bucket, next_value, updated_at) VALUES (1, 1, ?)')
        .run(new Date().toISOString());
      row = { bucket: 1, next_value: 1 };
    }
    const serial = row.next_value;
    this.db.prepare('UPDATE structure_code_sequence SET next_value = ?, updated_at = ? WHERE bucket = 1')
      .run(serial + 1, new Date().toISOString());
    // Provisional format. Carries no location information, so changing it is a
    // code-sequence change and not an identity migration.
    return `SLR-${zoneLetter}4${String(1000 + serial).slice(-4)}`;
  }

  /**
   * Apply a human decision.
   * @param {'merge'|'distinct'|'deferred'} decision
   */
  decideDedup(candidateId, decision, { reviewerId, note, classification, codeResolution }) {
    const c = this.db.prepare('SELECT * FROM dedup_candidate WHERE id = ?').get(candidateId);
    if (!c) throw new Error(`no such dedup candidate ${candidateId}`);

    const now = new Date().toISOString();
    if (decision === 'deferred') {
      this.db.prepare("UPDATE dedup_candidate SET state = 'deferred', reviewer_id = ?, reviewed_at = ?, decision_note = ? WHERE id = ?")
        .run(reviewerId, now, note ?? null, candidateId);
      return { decision, code: null };
    }

    if (decision === 'merge') {
      // structure_b is absorbed into structure_a. structure_a's code survives if
      // it has one; if neither carried a code (the common case — codes are only
      // issued post-decision), the survivor is coded NOW, as the direct
      // consequence of this human decision.
      let keep = this.getStructure(c.structure_a);
      const drop = this.getStructure(c.structure_b);
      if (!keep.code) {
        const issued = this.issueCode(c.structure_a, { reviewerId });
        keep = this.getStructure(c.structure_a);
        // PRD 6.1: a code may only attach to an already-surveyed structure.
        // A merge of two un-surveyed pins promotes the survivor to surveyed,
        // because the reviewer has just asserted it is a real, distinct unit.
        if (keep.status === 'candidate') {
          this.updateStructure(c.structure_a, { status: 'surveyed' });
          const retry = this.issueCode(c.structure_a, { reviewerId });
          keep = this.getStructure(c.structure_a);
        }
      }
      this.db.prepare('UPDATE structure_service SET structure_id = ? WHERE structure_id = ?')
        .run(c.structure_a, c.structure_b);
      // Soft delete only: a tombstone lets offline clients converge (C4).
      this.db.prepare('UPDATE structure SET deleted_at = ?, updated_at = ? WHERE id = ?')
        .run(now, now, c.structure_b);
      // If the two entrances collapse into one, that is the 6.1 outcome
      // multi_household_single_entry. Accept either camelCase or snake_case so a
      // caller cannot silently skip the reconciliation by using the other name.
      const mergedType = classification?.structure_type ?? classification?.structureType;
      if (mergedType === 'multi_household_single_entry') {
        this.db.prepare('UPDATE structure SET entrance_independent = 0 WHERE id = ?')
          .run(c.structure_a);
      }
      this.db.prepare("UPDATE dedup_candidate SET state = 'merged', reviewer_id = ?, reviewed_at = ?, decision_note = ? WHERE id = ?")
        .run(reviewerId, now, note ?? null, candidateId);
      return { decision, code: keep.code, merged: drop.id };
    }

    if (decision === 'distinct') {
      // Two structures, two destinations, TWO codes.
      const code = this.issueCode(c.structure_b, { reviewerId });
      if (classification) {
        const distinctType = classification.structure_type ?? classification.structureType;
        this.db.prepare(`
          UPDATE structure SET
            structure_type = COALESCE(?, structure_type),
            entrance_independent = COALESCE(?, entrance_independent),
            is_shared_wall = COALESCE(?, is_shared_wall),
            shares_wall_with = COALESCE(?, shares_wall_with),
            updated_at = ?
          WHERE id = ?
        `).run(
          distinctType ?? null,
          classification.entrance_independent == null ? null : (classification.entrance_independent ? 1 : 0),
          classification.is_shared_wall == null ? null : (classification.is_shared_wall ? 1 : 0),
          classification.shares_wall_with ?? null,
          now, c.structure_b,
        );
      }
      this.db.prepare("UPDATE dedup_candidate SET state = 'distinct', reviewer_id = ?, reviewed_at = ?, decision_note = ? WHERE id = ?")
        .run(reviewerId, now, note ?? null, candidateId);
      return { decision, code };
    }

    throw new Error(`unknown decision ${decision}`);
  }

  // -------------------------------------------------------------- assertions

  /**
   * Record an asserted value with its evidence class (C8).
   * Inference rows are always candidates; only a human observation is asserted.
   */
  recordAssertion({ entityTable = 'structure', entityId, field, value,
                     evidenceClass, source, observedBy, observedAt,
                     producedBy, producedAt, confidence }) {
    if (evidenceClass === 'inference') {
      // C8: inference can only ever be a candidate, never authoritative.
      const id = crypto.randomUUID();
      this.db.prepare(`
        INSERT INTO assertion (id, entity_table, entity_id, field, value,
          evidence_class, state, source, produced_by, produced_at, confidence, created_at)
        VALUES (?, ?, ?, ?, ?, 'inference', 'candidate', ?, ?, ?, ?, ?)
      `).run(id, entityTable, entityId, field, JSON.stringify(value), source,
        producedBy ?? 'ml', producedAt ?? new Date().toISOString(), confidence ?? null,
        new Date().toISOString());
      return { assertionId: id, state: 'candidate' };
    }

    // ground truth: supersede any prior asserted value for this field
    const prior = this.db.prepare(`
      SELECT id FROM assertion
      WHERE entity_table = ? AND entity_id = ? AND field = ? AND state = 'asserted'
    `).get(entityTable, entityId, field);
    if (prior) {
      this.db.prepare("UPDATE assertion SET state = 'superseded' WHERE id = ?").run(prior.id);
    }
    const id = crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO assertion (id, entity_table, entity_id, field, value,
        evidence_class, state, source, observed_by, observed_at, supersedes_id, created_at)
      VALUES (?, ?, ?, ?, ?, 'ground_truth', 'asserted', ?, ?, ?, ?, ?)
    `).run(id, entityTable, entityId, field, JSON.stringify(value), source,
      observedBy, observedAt ?? new Date().toISOString(), prior?.id ?? null,
      new Date().toISOString());
    return { assertionId: id, state: 'asserted', superseded: prior?.id ?? null };
  }

  // ------------------------------------------------------------------ reads

  getStructure(id) {
    return this.db.prepare('SELECT * FROM structure WHERE id = ?').get(id);
  }

  getByCode(code) {
    return this.db.prepare('SELECT * FROM structure WHERE code = ?').get(code);
  }

  allStructures(includeDeleted = false) {
    return includeDeleted
      ? this.db.prepare('SELECT * FROM structure ORDER BY created_at').all()
      : this.db.prepare('SELECT * FROM structure WHERE deleted_at IS NULL ORDER BY created_at').all();
  }


  // ------------------------------------------------------- dispatch support

  /**
   * Which zone contains this point, and is it dispatch-enabled?
   *
   * C7 (PRD 3): dispatch functions only inside the mapped zone. Containment is
   * computed, not asserted from a flag, so a structure cannot claim membership.
   *
   * Uses PostGIS when available and falls back to a bounding box otherwise, so
   * the in-memory test schema stays usable without the extension.
   */
  zoneFor(lat, lon, { dispatchEnabledOnly = true } = {}) {
    const rows = this.db.prepare('SELECT * FROM zone').all();
    for (const z of rows) {
      if (dispatchEnabledOnly && !z.dispatch_enabled) continue;
      if (z.radius_m != null) {
        // circular fallback (no geometry)
        const dx = (lon - z.lon) * 111320 * Math.cos((lat * Math.PI) / 180);
        const dy = (lat - z.lat) * 110540;
        if (Math.hypot(dx, dy) <= z.radius_m) return z;
      } else if (z.lon != null && z.lat != null) {
        const inLon = z.lon - 0.002 <= lon && lon <= z.lon + 0.002;
        const inLat = z.lat - 0.002 <= lat && lat <= z.lat + 0.002;
        if (inLon && inLat) return z;
      }
    }
    // Real containment against PostGIS geometry when the column exists.
    try {
      const geo = this.db.prepare(
        `SELECT code, name FROM zone
         WHERE dispatch_enabled = 1
           AND boundary IS NOT NULL
           AND ST_Contains(boundary, ST_SetSRID(ST_MakePoint($lon, $lat), 4326))
         LIMIT 1`,
      ).get({ $lon: lon, $lat: lat });
      if (geo) return geo;
    } catch {
      /* no PostGIS in this deployment */
    }
    return null;
  }

  /** Append-only audit of a verification observation (PRD 6.4). */
  recordVerificationEvent({ structureId, trigger_kind, source, outcome, payload, actor }) {
    this.db.prepare(`
      INSERT INTO verification_event (structure_id, trigger_kind, source, outcome, payload, actor, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(structureId, trigger_kind, source, outcome ?? null,
      JSON.stringify(payload ?? {}), actor ?? 'system', new Date().toISOString());
  }

  /** Mapper worklist. Fast-signal items rank first (PRD 6.4). */
  enqueueTask({ structure_id, zone, kind, signal, priority = 5,
                 note = null, payload = null }) {
    const id = crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO task (id, structure_id, zone, kind, signal, priority, state,
                        note, payload_json, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 'open', ?, ?, ?)
    `).run(id, structure_id ?? null, zone ?? null, kind, signal, priority,
      note, payload ? JSON.stringify(payload) : null, new Date().toISOString());
    return id;
  }

  openTasks() {
    return this.db.prepare(
      "SELECT * FROM task WHERE state = 'open' ORDER BY priority ASC, created_at ASC",
    ).all();
  }

  createStructure(fields) {
    const now = new Date().toISOString();
    const id = fields.id ?? crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO structure (id, status, structure_type, non_residential_subtype,
        lat, lon, entrance_lat, entrance_lon, entrance_independent,
        is_shared_wall, floors_estimated, material_primary, occupancy_estimate,
        version, created_by, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
    `).run(
      id,
      fields.status ?? 'surveyed',
      fields.structureType ?? 'standalone_dwelling',
      fields.nonResidentialSubtype ?? null,
      fields.lat, fields.lon,
      fields.entranceLat ?? null, fields.entranceLon ?? null,
      fields.entranceIndependent == null ? null : (fields.entranceIndependent ? 1 : 0),
      fields.isSharedWall ? 1 : 0,
      fields.floorsEstimated ?? null, fields.materialPrimary ?? null,
      fields.occupancyEstimate ?? null,
      fields.createdBy ?? 'system', now, now,
    );
    return id;
  }

  updateStructure(id, patch) {
    const cols = [];
    const vals = [];
    const map = {
      status: 'status', structureType: 'structure_type',
      nonResidentialSubtype: 'non_residential_subtype',
      entranceIndependent: 'entrance_independent', isSharedWall: 'is_shared_wall',
      floorsEstimated: 'floors_estimated', materialPrimary: 'material_primary',
      occupancyEstimate: 'occupancy_estimate', disclosurePolicy: 'disclosure_policy',
      dedupThresholdM: 'dedup_threshold_m',
    };
    for (const [k, col] of Object.entries(map)) {
      if (patch[k] !== undefined) { cols.push(`${col} = ?`); vals.push(patch[k]); }
    }
    if (!cols.length) return;
    cols.push('version = version + 1', 'updated_at = ?');
    vals.push(new Date().toISOString(), id);
    this.db.prepare(`UPDATE structure SET ${cols.join(', ')} WHERE id = ?`).run(...vals);
  }

  // ------------------------------------------------------------------- sync

  /**
   * Apply a batch of queued offline operations.
   *
   * Ops apply in client-seq order. A single failure does not abort the batch,
   * and only failed ops are retried by the caller. Identity conflicts return
   * dedup_required — never a silent merge (C2).
   */
  push({ deviceId, ops = [], mapperId = 'unknown' }) {
    const results = [];
    const sorted = [...ops].sort((a, b) => a.clientSeq - b.clientSeq);

    for (const op of sorted) {
      // Idempotency: a replay returns the original receipt.
      const prior = this.receipt(op.clientOpId);
      if (prior) {
        results.push({
          clientOpId: op.clientOpId, state: 'replayed',
          serverId: prior.entity_id, version: prior.server_version,
        });
        continue;
      }

      try {
        if (op.table === 'local_structure' && op.op === 'create') {
          const pl = op.payload || {};
          const centroid = pl.centroid || {};
          const entrance = pl.entrance_geom;
          const id = this.createStructure({
            status: 'surveyed',
            structureType: pl.structure_type,
            entranceLat: entrance?.lat ?? null,
            entranceLon: entrance?.lon ?? null,
            entranceIndependent: pl.entrance_independent,
            isSharedWall: pl.is_shared_wall,
            floorsEstimated: pl.floors_estimated,
            materialPrimary: pl.material_primary,
            occupancyEstimate: pl.occupancy_estimate,
            lat: centroid.lat, lon: centroid.lon,
            createdBy: mapperId,
          });

          // Every captured value is a mapper GROUND TRUTH assertion (C8).
          for (const [field, value] of Object.entries({
            centroid, entrance_geom: entrance ?? null,
            structure_type: pl.structure_type,
            entrance_independent: pl.entrance_independent ?? null,
            floors_estimated: pl.floors_estimated ?? null,
          })) {
            if (value === null || value === undefined) continue;
            this.recordAssertion({
              entityId: id, field, value,
              evidenceClass: 'ground_truth',
              source: 'mapper_survey',
              observedBy: `mapper:${mapperId}`,
              observedAt: pl.observed_at,
            });
          }

          const dupId = this.generateDedupCandidate(id);
          if (dupId) {
            const c = this.db.prepare('SELECT * FROM dedup_candidate WHERE id = ?').get(dupId);
            results.push({
              clientOpId: op.clientOpId, state: 'dedup_required',
              serverId: id, dedupCandidateId: dupId,
              nearestStructure: { serverId: c.structure_a, distance_m: c.distance_m },
            });
            this.recordReceipt({
              clientOpId: op.clientOpId, clientSeq: op.clientSeq, mapperId,
              table: op.table, entityId: id, serverVersion: 1,
            });
            continue;
          }

          this.recordReceipt({
            clientOpId: op.clientOpId, clientSeq: op.clientSeq, mapperId,
            table: op.table, entityId: id, serverVersion: 1,
          });
          results.push({ clientOpId: op.clientOpId, state: 'applied', serverId: id, version: 1 });
          continue;
        }

        if (op.table === 'local_structure' && op.op === 'update') {
          const s = this.getStructure(op.entityId);
          if (!s) {
            results.push({ clientOpId: op.clientOpId, state: 'rejected', reason: 'unknown_structure' });
            continue;
          }
          if (s.code === null) {
            results.push({
              clientOpId: op.clientOpId, state: 'rejected',
              reason: 'structure_in_dedup_review',
              detail: 'unconfirmed structure: identity is a human decision (C2)',
            });
            continue;
          }
          // Confirmed structure: field-level CRDT merge is allowed.
          // Validate against the mergeable allow-list (throws on identity
          // fields), then apply each field whose Lamport clock wins.
          mergeFields({}, op.payload?.fields ?? {}, 'structure');
          const FIELD_MAP = {
            structure_type: 'structureType',
            non_residential_subtype: 'nonResidentialSubtype',
            entrance_independent: 'entranceIndependent',
            floors_estimated: 'floorsEstimated',
            material_primary: 'materialPrimary',
            occupancy_estimate: 'occupancyEstimate',
            is_shared_wall: 'isSharedWall',
          };
          const patch = {};
          for (const [field, inc] of Object.entries(op.payload?.fields ?? {})) {
            const cur = this.db.prepare(
              'SELECT lamport, site_id FROM field_version WHERE entity_id = ? AND field = ?'
            ).get(op.entityId, field);
            const wins = !cur || inc.lamport > cur.lamport ||
              (inc.lamport === cur.lamport && String(inc.siteId) >= String(cur.site_id));
            if (!wins) continue;
            this.db.prepare(
              `INSERT INTO field_version (entity_id, field, lamport, site_id) VALUES (?, ?, ?, ?)
               ON CONFLICT(entity_id, field) DO UPDATE SET lamport = excluded.lamport, site_id = excluded.site_id`
            ).run(op.entityId, field, inc.lamport, inc.siteId ?? mapperId);
            if (FIELD_MAP[field]) {
              let v = inc.value;
              if (field === 'entrance_independent' || field === 'is_shared_wall') v = v ? 1 : 0;
              patch[FIELD_MAP[field]] = v;
            }
            this.recordAssertion({
              entityId: op.entityId, field, value: inc.value,
              evidenceClass: 'ground_truth', source: 'mapper_survey',
              observedBy: `mapper:${mapperId}`,
            });
          }
          if (Object.keys(patch).length) this.updateStructure(op.entityId, patch);
          const after = this.getStructure(op.entityId);
          this.recordReceipt({
            clientOpId: op.clientOpId, clientSeq: op.clientSeq, mapperId,
            table: op.table, entityId: op.entityId, serverVersion: after.version,
          });
          results.push({
            clientOpId: op.clientOpId, state: 'applied',
            serverId: op.entityId, version: after.version,
          });
          continue;
        }

        results.push({
          clientOpId: op.clientOpId, state: 'rejected',
          reason: `unsupported: ${op.table}/${op.op}`,
        });
      } catch (e) {
        if (e instanceof IdentityMergeRefused) {
          results.push({
            clientOpId: op.clientOpId, state: 'rejected',
            reason: 'identity_merge_refused', detail: e.message,
          });
        } else {
          results.push({
            clientOpId: op.clientOpId, state: 'rejected',
            reason: 'error', detail: e.message,
          });
        }
      }
    }
    return { results, serverTime: new Date().toISOString() };
  }

  /** Cursor-based pull. Server time is authoritative; client clocks are not trusted. */
  pull({ since = null, zone = 'C4', limit = 1000 } = {}) {
    // Cursor format: srv:<updated_at>:<id>. Only rows after it are returned.
    let sinceTs = null; let sinceId = null;
    if (since && String(since).startsWith('srv:')) {
      const rest = String(since).slice(4);
      const sep = rest.lastIndexOf(':');
      sinceTs = rest.slice(0, sep);
      sinceId = rest.slice(sep + 1);
    }
    let structures;
    if (sinceTs) {
      structures = this.db.prepare(
        `SELECT * FROM structure WHERE updated_at > ? OR (updated_at = ? AND id > ?)
         ORDER BY updated_at ASC, id ASC LIMIT ?`).all(sinceTs, sinceTs, sinceId || '', limit);
    } else {
      structures = this.db.prepare(
        'SELECT * FROM structure ORDER BY updated_at ASC, id ASC LIMIT ?').all(limit);
    }
    const changes = [];
    for (const s of structures) {
      changes.push({
        table: 'local_structure', entity_id: s.id, op: 'update',
        payload: s, version: s.version,
      });
    }
    const last = structures[structures.length - 1];
    const cursor = last ? `srv:${last.updated_at}:${last.id}` : since;
    return {
      cursor, has_more: structures.length === limit, changes,
      serverTime: new Date().toISOString(),
    };
  }

  /** Full mapped-zone pre-seed. Deliberately excludes anything identity-related. */
  bootstrap({ zone = 'C4' } = {}) {
    return {
      zone,
      structures: this.allStructures(false),
      services: this.db.prepare('SELECT * FROM structure_service').all(),
      serverTime: new Date().toISOString(),
    };
  }

  health() {
    return {
      serverTime: new Date().toISOString(),
      structures: this.allStructures(false).length,
      dedup_open: this.db
        .prepare("SELECT COUNT(*) AS n FROM dedup_candidate WHERE state = 'open'").get().n,
      maintenance: false,
    };
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function round(n) { return Math.round(n * 100) / 100; }

/**
 * Ranking only. Weights the six PRD 6.1 signals, but NO threshold decides:
 * a high score means "look at this", never "same building".
 */
function scoreSignals(s) {
  let score = 0;
  if (s.distance_m != null) score += Math.max(0, 1 - s.distance_m / 12) * 0.25;
  if (s.entrance_dist_m != null) {
    // entrances far apart is evidence of SEPARATE destinations, which lowers
    // the merge likelihood — deliberately not symmetric with distance
    score += Math.min(1, s.entrance_dist_m / 20) * 0.2;
  }
  if (s.wall_shared) score += 0.2;
  if (s.mapper_conflict) score += 0.25;
  if (s.photo_similarity != null) score += s.photo_similarity * 0.1;
  return Math.min(1, round(score * 100) / 100);
}

module.exports = {
  Registry, mergeField, mergeFields, MERGEABLE, IDENTITY_FIELDS,
  IdentityMergeRefused, haversine, scoreSignals,
};