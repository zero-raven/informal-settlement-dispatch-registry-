/**
 * Dispatch backends.
 *
 * PRD §3 RESOLVED: the internal dispatch interface is the only implemented
 * backend for this semester. No CAD/AVL integration is designed or estimated
 * here.
 *
 * The abstraction exists so a future external backend is ADDITIVE rather than
 * invasive: the core registry depends on this interface, never on a concrete
 * implementation, so an adapter slots in behind the same configuration switch
 * without touching routes, schema, or clients.
 *
 * MVP flow: Structure ID -> dispatch lookup -> location -> route -> responder
 *           -> dispatch outcome.
 */

'use strict';

const crypto = require('node:crypto');

/**
 * The contract every backend must satisfy.
 *
 * `registry-api` depends only on this. InternalBackend is one implementation;
 * a future ExternalBackend would implement the same four methods.
 */
class DispatchBackend {
  /** @returns {{code:string, lat:number, lon:number, name:string}} */
  // eslint-disable-next-line no-unused-vars
  async lookup(code, responderLocation, profile) {
    throw new Error('lookup() not implemented');
  }

  /** Hand a destination to a responder. @returns {{dispatch_id:string}} */
  // eslint-disable-next-line no-unused-vars
  async dispatch(code, context) {
    throw new Error('dispatch() not implemented');
  }

  /** Record success/failure. Feeds the fast signal (PRD 6.4). */
  // eslint-disable-next-line no-unused-vars
  async outcome(dispatchId, result) {
    throw new Error('outcome() not implemented');
  }

  /** Advertise what this backend supports, so the UI can degrade honestly. */
  async capabilities() {
    throw new Error('capabilities() not implemented');
  }
}

/**
 * The MVP backend: the registry itself.
 *
 * Routes are computed by the graph service; when no graph is available the
 * destination is still returned with `reachable:false`, because "the structure
 * exists and here is where it is" is more useful to a dispatcher than an error.
 */
class InternalBackend extends DispatchBackend {
  /**
   * @param {{
   *   registry: object,
   *   router?: (from: {lat:number,lon:number}, to: {lat:number,lon:number}, opts?: object) => object,
   * }} deps
   */
  constructor({ registry, router = null } = {}) {
    super();
    if (!registry) throw new Error('InternalBackend requires a registry');
    this.registry = registry;
    this.router = router;
    this.outcomes = [];
    this.responders = [];
  }

  async capabilities() {
    return {
      backend: 'internal',
      name: 'Internal dispatch (MVP)',
      profiles: ['foot'],
      supportsOfflineCache: true,
      supportsZoneGating: true,
      supportsExternalHandoff: false,
      supportsOccupantContext: true,
    };
  }

  async stats() {
    const db = this.registry.db;
    // Total dispatches (assigned + outcomes)
    const total = db.prepare('SELECT COUNT(*) as c FROM dispatcher_responders').get().c;
    const successful = db.prepare("SELECT COUNT(*) as c FROM dispatcher_outcomes WHERE outcome = 'confirmed'").get().c;
    const failed = db.prepare("SELECT COUNT(*) as c FROM dispatcher_outcomes WHERE outcome = 'failed'").get().c;
    const active = total - successful - failed;
    const today = new Date().toISOString().split('T')[0];
    const todayStarted = db.prepare("SELECT COUNT(*) as c FROM dispatcher_responders WHERE at LIKE ?").get(`${today}%`).c;
    const pendingReview = failed; // failed outcomes need review
    const avgResponseTime = 15; // placeholder

    return {
      total,
      successful,
      failed,
      active,
      todayStarted,
      pendingReview,
      successRate: total > 0 ? Math.round((successful / total) * 100) : 0,
      avgResponseTime,
    };
  }

  async recent(limit = 10) {
    const db = this.registry.db;
    const rows = db.prepare(`
      SELECT r.dispatch_id, r.code, r.responder, r.at as assigned_at,
             o.outcome, o.at as outcome_at
      FROM dispatcher_responders r
      LEFT JOIN dispatcher_outcomes o ON r.dispatch_id = o.dispatch_id
      ORDER BY r.at DESC
      LIMIT ?
    `).all(limit);

    return rows.map(row => ({
      dispatch_id: row.dispatch_id,
      code: row.code,
      responder: row.responder,
      assigned_at: row.assigned_at,
      outcome: row.outcome,
      outcome_at: row.outcome_at,
    }));
  }

  async lookup(code, responderLocation, profile = 'foot') {
    const s = this.registry.getByCode(code);
    if (!s) {
      return { error: 'structure_not_found', code, http: 404 };
    }
    // A merged-away structure's code must read as STALE, not merely unknown:
    // a responder following an out-of-date placard needs to know it is stale.
    if (s.deleted_at) {
      return { error: 'code_superseded', code, http: 404 };
    }

    // C1/C2: identity must be settled before anyone is sent anywhere.
    if (!s.code) {
      return { error: 'code_not_finalized', code, http: 409 };
    }
    if (s.status === 'disputed') {
      return { error: 'structure_in_dedup_review', code, http: 409 };
    }

    const destination = { lat: s.lat, lon: s.lon };

    // C7: dispatch is gated on containment inside a dispatch-enabled zone.
    const zone = this.registry.zoneFor(s.lat, s.lon, { dispatchEnabledOnly: true });
    if (!zone) {
      return {
        error: 'outside_mapped_zone', code, http: 403,
        detail: 'structure centroid is outside every dispatch-enabled zone',
        destination,
      };
    }

    const result = {
      code,
      destination,
      zone: { code: zone.code, name: zone.name, dispatch_enabled: true },
      structure: {
        status: s.status,
        structure_type: s.structure_type,
        floors_estimated: s.floors_estimated,
        entrance_lat: s.entrance_lat,
        entrance_lon: s.entrance_lon,
      },
      route: null,
      backend: 'internal',
    };

    if (responderLocation && this.router) {
      result.route = this.router(
        { lat: responderLocation.lat, lon: responderLocation.lon },
        destination,
        { profile },
      );
    }
    return result;
  }

  async dispatch(code, context = {}) {
    const id = crypto.randomUUID();
    const at = new Date().toISOString();
    this.responders.push({ dispatch_id: id, code, at, ...context });
    // Persist to database
    this.registry.db.prepare(`
      INSERT INTO dispatcher_responders (dispatch_id, code, responder, at)
      VALUES (?, ?, ?, ?)
    `).run(id, code, context.responder ?? null, at);
    return { dispatch_id: id, code, status: 'assigned', responder: context.responder ?? null };
  }

  /**
   * Record the outcome. A `failed` outcome is the FAST SIGNAL (PRD 6.4) and
   * opens a re-verification task; a `confirmed` observation is ground truth
   * (C8) and may supersede a mapper's record.
   */
  async outcome(dispatchId, result = {}) {
    const rec = { dispatch_id: dispatchId, ...result, at: new Date().toISOString() };
    this.outcomes.push(rec);
    // Persist to database
    this.registry.db.prepare(`
      INSERT INTO dispatcher_outcomes (dispatch_id, outcome, structure_id, actor, at)
      VALUES (?, ?, ?, ?, ?)
    `).run(dispatchId, result.outcome ?? 'confirmed', result.structure_id ?? null, result.actor ?? `dispatch:${dispatchId.slice(0, 8)}`, rec.at);

    if (result.outcome === 'failed') {
      this.registry.recordVerificationEvent({
        structureId: result.structure_id,
        trigger_kind: 'fast',
        source: 'dispatch_feedback',
        outcome: 'changed',
        payload: result,
        actor: result.actor ?? `dispatch:${dispatchId.slice(0, 8)}`,
      });
      this.registry.enqueueTask({
        structure_id: result.structure_id,
        kind: 'dispatch_failure',
        signal: 'fast',
        priority: 1,
      });
    }
    if (result.outcome === 'confirmed' && result.structure_id) {
      // A responder who reached the scene OBSERVED the place. That is ground
      // truth and may supersede a mapper's record — the one non-inference way
      // to overwrite ground truth (C8).
      this.registry.recordVerificationEvent({
        structureId: result.structure_id,
        trigger_kind: 'fast',
        source: 'dispatch_feedback',
        outcome: 'confirmed',
        payload: result,
        actor: result.actor ?? `dispatch:${dispatchId.slice(0, 8)}`,
      });
    }
    return { recorded: true, dispatch_id: dispatchId };
  }
}

/**
 * Select a backend by configuration.
 *
 * Only 'internal' exists this semester. An 'external' key would resolve to a
 * future adapter implementing the same interface; nothing in the core would
 * change when that lands.
 */
function createBackend(name, deps) {
  switch (name) {
    case 'internal':
    default:
      return new InternalBackend(deps);
    // A future CAD/AVL/NGO adapter registers here. NOT DESIGNED, NOT ESTIMATED.
    // case 'external':
    //   return new ExternalBackend(deps);
  }
}

module.exports = { DispatchBackend, InternalBackend, createBackend };