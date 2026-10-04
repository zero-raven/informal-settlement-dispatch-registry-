/**
 * Feedback and re-verification engine.
 *
 * PRD §6.4 two-speed model:
 *   FAST  — dispatch failure, resident complaint. Real-time.
 *   SLOW  — imagery diffing. Weeks-to-months, bounded by free-imagery refresh.
 *
 * C8 pipeline, the only permitted flow:
 *   Inference -> Candidate change -> Verification -> Ground-truth update
 *
 * An inference component can only ever create a CANDIDATE. A mapper, responder,
 * reviewer, admin, or a resident (for their own report) is the only principal
 * that can promote one. REJECTION is a first-class outcome: most imagery
 * candidates should be rejected, and recording that is a result, not a failure.
 */

'use strict';

const crypto = require('node:crypto');

/** Fast-signal work outranks slow-signal work without exception (PRD 6.4). */
const SIGNAL_RANK = { fast: 0, slow: 1, manual: 0, bootstrap: 2 };

class FeedbackEngine {
  /**
   * @param {{
   *   registry: object,
   *   allowPromotionBy?: (actor) => boolean,
   * }} deps
   */
  constructor({ registry, allowPromotionBy = defaultPromoter }) {
    if (!registry) throw new Error('FeedbackEngine requires a registry');
    this.registry = registry;
    this.allowPromotionBy = allowPromotionBy;
  }

  // ------------------------------------------------------------ task intake

  /**
   * Raise a task. `signal` decides its rank; within a signal, `priority`
   * orders the work.
   */
  raiseTask({ structureId = null, zone = null, kind, signal, note = null,
              payload = null, priority = null }) {
    // NOTE: SIGNAL_RANK['fast'] is 0, which is FALSY. Testing the truthiness
    // of the rank would reject the fastest signal and accept the slow ones —
    // precisely backwards. Test for presence instead.
    if (!Object.hasOwn(SIGNAL_RANK, signal)) {
      throw new Error(`unknown signal "${signal}"`);
    }
    const rank = SIGNAL_RANK[signal];
    const effective = priority ?? (signal === 'fast' ? 1 : signal === 'slow' ? 6 : 5);
    const id = this.registry.enqueueTask({
      structure_id: structureId,
      zone,
      kind,
      signal,
      priority: rank * 100 + effective,   // rank dominates
      note,
      payload,
    });
    return { taskId: id, rank: rank * 100 + effective };
  }

  /**
   * The mapper worklist. Fast-signal items first, always — a responder who
   * could not reach a structure outranks an imagery pixel that looks different.
   */
  worklist({ assignee = null, limit = 100 } = {}) {
    const rows = this.registry.db
      .prepare("SELECT * FROM task WHERE state = 'open' ORDER BY priority ASC, created_at ASC LIMIT ?")
      .all(limit);
    return rows.filter((t) => !assignee || t.assignee === assignee);
  }

  // ------------------------------------------------- C8 candidate pipeline

  /**
   * Record an inference output. ALWAYS a candidate, never authoritative.
   *
   * This is the only entry point any AI or imagery component may use, and it
   * physically cannot produce ground truth: the value is written with
   * evidence_class 'inference' and state 'candidate', and the registry's own
   * constraint refuses anything else.
   */
  raiseCandidate({ entityTable = 'structure', entityId, field, value,
                   source, producedBy, confidence = null, reason = null,
                   opensTask = true }) {
    const out = this.registry.recordAssertion({
      entityTable,
      entityId,
      field,
      value,
      evidenceClass: 'inference',
      source,
      producedBy,
      confidence,
    });

    let taskId = null;
    if (opensTask) {
      // Slow signal: imagery is a weeks-to-months cadence, ranked below fast.
      ({ taskId } = this.raiseTask({
        structureId: entityId,
        kind: source === 'imagery_diff' ? 'imagery_resurvey' : 'inference_review',
        signal: 'slow',
        note: reason,
        payload: { assertionId: out.assertionId, field, value },
      }));
    }
    return { assertionId: out.assertionId, state: 'candidate', taskId };
  }

  /**
   * THE ONLY path from candidate to ground truth.
   *
   * `actor` must be a person. A non-human principal is refused outright — this
   * is C8 enforced at the application boundary as well as in the database.
   */
  verify({ assertionId, outcome, value = null, actor, note = null }) {
    if (!this.allowPromotionBy(actor)) {
      const err = new Error(
        `inference cannot verify (C8): "${actor}" is not a human principal`);
      err.code = 'inference_cannot_verify';
      err.http = 403;
      throw err;
    }
    if (!['confirmed', 'rejected'].includes(outcome)) {
      throw new Error(`outcome must be confirmed or rejected, got "${outcome}"`);
    }

    const cand = this.registry.db
      .prepare('SELECT * FROM assertion WHERE id = ?')
      .get(assertionId);
    if (!cand) throw new Error(`no such assertion ${assertionId}`);
    if (cand.evidence_class !== 'inference') {
      // already ground truth: verifying it again is a no-op, not an error
      return { state: cand.state, alreadyGroundTruth: true };
    }

    if (outcome === 'rejected') {
      // A first-class outcome. The candidate is closed, and the PRIOR ground
      // truth is untouched — rejecting a candidate must never clear a value.
      this.registry.db
        .prepare("UPDATE assertion SET state = 'rejected' WHERE id = ?")
        .run(assertionId);
      this.registry.db
        .prepare("UPDATE task SET state = 'done', outcome = 'rejected', completed_at = ? WHERE payload_json LIKE ?")
        .run(new Date().toISOString(), `%"assertionId":"${assertionId}"%`);
      this.registry.recordVerificationEvent({
        structureId: cand.entity_id,
        trigger_kind: 'slow',
        source: cand.source,
        outcome: 'inconclusive',
        payload: { assertionId, rejected: true, note },
        actor,
      });
      return { state: 'rejected', groundTruthUnchanged: true };
    }

    // confirmed: write the ground-truth row and supersede the prior value
    const written = this.registry.recordAssertion({
      entityTable: cand.entity_table,
      entityId: cand.entity_id,
      field: cand.field,
      value: value ?? JSON.parse(cand.value),
      evidenceClass: 'ground_truth',
      source: cand.source,
      observedBy: actor,
      observedAt: new Date().toISOString(),
    });
    this.registry.db
      .prepare("UPDATE assertion SET state = 'confirmed' WHERE id = ?")
      .run(assertionId);
    this.registry.db
      .prepare("UPDATE task SET state = 'done', outcome = 'confirmed', completed_at = ? WHERE payload_json LIKE ?")
      .run(new Date().toISOString(), `%"assertionId":"${assertionId}"%`);

    this.registry.recordVerificationEvent({
      structureId: cand.entity_id,
      trigger_kind: cand.source === 'imagery_diff' ? 'slow' : 'manual',
      source: cand.source,
      outcome: 'changed',
      payload: { assertionId, field: cand.field, value: written, note },
      actor,
    });
    // Spread FIRST: `written.state` is 'asserted', which is the ground-truth
    // state. Spreading after would silently overwrite the pipeline's own
    // vocabulary. Expose both, unambiguously.
    return { ...written, pipelineState: 'confirmed', state: 'confirmed' };
  }

  // ------------------------------------------------------------ task closing

  /**
   * Complete a task directly, without a candidate — the mapper walked the path
   * and confirmed the structure is fine. That IS an observation (C8).
   */
  completeTask({ taskId, outcome = 'confirmed', actor, note = null, updates = null }) {
    if (!this.allowPromotionBy(actor)) {
      const err = new Error(`non-human principal cannot complete a task (C8): ${actor}`);
      err.code = 'inference_cannot_verify';
      err.http = 403;
      throw err;
    }
    const task = this.registry.db.prepare('SELECT * FROM task WHERE id = ?').get(taskId);
    if (!task) throw new Error(`no such task ${taskId}`);

    for (const [field, v] of Object.entries(updates ?? {})) {
      this.registry.recordAssertion({
        entityId: task.structure_id,
        field,
        value: v,
        evidenceClass: 'ground_truth',
        source: 'mapper_survey',
        observedBy: actor,
      });
    }
    this.registry.db
      .prepare("UPDATE task SET state = 'done', outcome = ?, completed_at = ?, assignee = ? WHERE id = ?")
      .run(outcome, new Date().toISOString(), actor, taskId);
    this.registry.recordVerificationEvent({
      // A zone- or bootstrap-level task may have no structure; the audit trail
      // must accept that rather than refusing the completion.
      structureId: task.structure_id,
      trigger_kind: task.signal === 'fast' ? 'fast' : 'manual',
      source: 'mapper_survey',
      outcome,
      payload: { taskId, note },
      actor,
    });
    return { taskId, outcome, updatesApplied: Object.keys(updates ?? {}).length };
  }

  /** Defer without deciding — the honest move when a mapper cannot tell. */
  deferTask({ taskId, actor, note }) {
    this.registry.db
      .prepare("UPDATE task SET state = 'deferred', assignee = ?, note = ? WHERE id = ?")
      .run(actor, note ?? null, taskId);
    return { taskId, state: 'deferred' };
  }

  /** Queue statistics, for the M8 evaluation metrics. */
  stats() {
    const rows = this.registry.db.prepare('SELECT * FROM task').all();
    const bySignal = {};
    for (const t of rows) bySignal[t.signal] = (bySignal[t.signal] ?? 0) + 1;
    const done = rows.filter((t) => t.state === 'done');
    const rejected = done.filter((t) => t.outcome === 'rejected').length;
    return {
      total: rows.length,
      open: rows.filter((t) => t.state === 'open').length,
      bySignal,
      completed: done.length,
      rejected,
      // candidate -> ground-truth conversion rate (M8 metric)
      conversion_rate: done.length ? round((done.length - rejected) / done.length, 4) : null,
    };
  }

  /** Assertions awaiting a human, across every inference source. */
  pendingCandidates({ type = null, limit = 200 } = {}) {
    let sql = "SELECT * FROM assertion WHERE evidence_class = 'inference' AND state = 'candidate' ORDER BY created_at DESC LIMIT ?";
    if (type) {
      sql = "SELECT * FROM assertion WHERE evidence_class = 'inference' AND state = 'candidate' AND source = ? ORDER BY created_at DESC LIMIT ?";
      return this.registry.db.prepare(sql).all(type, limit);
    }
    return this.registry.db.prepare(sql).all(limit);
  }
}

/**
 * Who may promote a candidate to ground truth.
 *
 * Only humans. An ML service, an imagery job, or any principal whose id starts
 * with a service prefix is refused.
 */
function defaultPromoter(actor) {
  if (!actor || typeof actor !== 'string') return false;
  if (/^(ml|imagery|system|auto|change-detector|graph)/i.test(actor)) return false;
  return /^(mapper|dispatch|reviewer|admin|resident):/.test(actor);
}

function round(n, d) {
  const f = 10 ** d;
  return Math.round(n * f) / f;
}

module.exports = { FeedbackEngine, SIGNAL_RANK, defaultPromoter };