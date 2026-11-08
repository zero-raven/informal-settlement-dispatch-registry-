/**
 * HTTP surface over the Registry.
 *
 * Deliberately thin: M2's substance is in registry.js, which is where the
 * constraint tests run. This exists so the mapper app has a real endpoint and
 * so the sync contract in docs/api.md is executable rather than aspirational.
 *
 * Auth is stubbed at the edge (role header) — OIDC lands in M6. The DB-level
 * guards (C1/C2/C8) do not depend on it and are enforced regardless.
 */

'use strict';

const http = require('node:http');
const { Registry } = require('./registry.js');
const { renderQr } = require('./qr.js');
const { createBackend } = require('./dispatch.js');
const { FeedbackEngine } = require('./feedback.js');
const { readServiceData, aggregateStats, DisclosureRefused } = require('./disclosure.js');

const PORT = Number(process.env.PORT || 8090);

function json(res, code, body) {
  const s = JSON.stringify(body);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, X-Role',
    'Access-Control-Allow-Methods': 'GET,POST,PATCH,OPTIONS',
  });
  res.end(s);
}

function createServer({
  registry = new Registry(process.env.DB_PATH || ':memory:'),
  backendName = process.env.DISPATCH_BACKEND || 'internal',
  router = null,
} = {}) {
  // Optional graph-service routing: when GRAPH_URL is set, lookup asks the
  // graph service for a route. Any failure degrades to route:null — the
  // destination is still returned, never a fabricated path.
  const graphUrl = process.env.GRAPH_URL || null;
  if (!router && graphUrl) {
    router = async (from, to, opts) => {
      try {
        const res = await fetch(`${graphUrl.replace(/\/$/, '')}/v1/graph/route`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ from, to, profile: opts?.profile || 'foot' }),
        });
        if (!res.ok) return null;
        return await res.json();
      } catch { return null; }
    };
  }
  // PRD 3: the backend is configuration-selected, and the core depends only on
  // the interface. A future external adapter registers here unchanged.
  const backend = createBackend(backendName, { registry, router });
  const feedback = new FeedbackEngine({ registry });

  const srv = http.createServer(async (req, res) => {
    if (req.method === 'OPTIONS') return json(res, 204, {});

    const url = new URL(req.url, `http://${req.headers.host}`);
    const role = req.headers['x-role'] || 'mapper';

    const body = async () => {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      return chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
    };

    try {
      // ---- sync ------------------------------------------------------------
      if (req.method === 'POST' && url.pathname === '/v1/sync/push') {
        const b = await body();
        return json(res, 200, registry.push({
          deviceId: b.device_id, ops: b.ops || [], mapperId: role,
        }));
      }
      if (req.method === 'GET' && url.pathname === '/v1/sync/pull') {
        return json(res, 200, registry.pull({
          since: url.searchParams.get('since'),
          zone: url.searchParams.get('zone') || 'C4',
          limit: Number(url.searchParams.get('limit') || 1000),
        }));
      }
      if (req.method === 'GET' && url.pathname === '/v1/sync/bootstrap') {
        return json(res, 200, registry.bootstrap({ zone: url.searchParams.get('zone') || 'C4' }));
      }
      if (req.method === 'GET' && url.pathname === '/v1/sync/health') {
        return json(res, 200, registry.health());
      }

      // ---- structures ------------------------------------------------------
      if (req.method === 'GET' && url.pathname === '/v1/structures') {
        return json(res, 200, { structures: registry.allStructures(false) });
      }
      // Exact segment count only: a bare /:code lookup must not swallow
      // /:code/qr, which would resolve 'qr' as a structure code.
      const structMatch = url.pathname.match(/^\/v1\/structures\/([^/]+)$/);
      if (req.method === 'GET' && structMatch) {
        const code = decodeURIComponent(structMatch[1]);
        const s = registry.getByCode(code);
        if (!s) return json(res, 404, { error: 'structure_not_found', code });
        if (s.deleted_at) {
          // a stale placard must say so, not merely "unknown" (PRD 6.5)
          return json(res, 404, { error: 'code_superseded', code });
        }
        return json(res, 200, s);
      }

      // ---- dedup review ----------------------------------------------------
      if (req.method === 'GET' && url.pathname === '/v1/dedup') {
        if (role !== 'reviewer' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'reviewer role required' });
        }
        return json(res, 200, {
          items: registry.openDedupQueue(url.searchParams.get('state') || 'open'),
        });
      }
      if (req.method === 'POST' && url.pathname.endsWith('/decision')) {
        if (role !== 'reviewer' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'reviewer role required' });
        }
        const id = url.pathname.split('/')[3];  // /v1/dedup/:id/decision
        const b = await body();
        try {
          return json(res, 200, registry.decideDedup(id, b.decision, {
            reviewerId: req.headers['x-user'] || 'reviewer',
            note: b.note,
            classification: b.classification,
            codeResolution: b.code_resolution,
          }));
        } catch (e) {
          return json(res, 409, { error: 'decision_failed', detail: e.message });
        }
      }

      // ---- QR --------------------------------------------------------------
      if (req.method === 'GET' && /^\/v1\/structures\/[^/]+\/qr$/.test(url.pathname)) {
        const code = url.pathname.split('/')[3];
        const s = registry.getByCode(code);
        if (!s || s.deleted_at) {
          return json(res, 404, { error: s?.deleted_at ? 'code_superseded' : 'structure_not_found', code });
        }
        return json(res, 200, await renderQr(code));
      }

      // ---- dispatch -------------------------------------------------------
      if (req.method === 'GET' && url.pathname === '/v1/dispatch/capabilities') {
        return json(res, 200, await backend.capabilities());
      }

      if (req.method === 'GET' && url.pathname === '/v1/dispatch/stats') {
        if (role !== 'dispatcher' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher role required' });
        }
        return json(res, 200, await backend.stats());
      }

      if (req.method === 'GET' && url.pathname === '/v1/dispatch/recent') {
        if (role !== 'dispatcher' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher role required' });
        }
        const limit = Number(url.searchParams.get('limit') || 10);
        return json(res, 200, { dispatches: await backend.recent(limit) });
      }

      if (req.method === 'POST' && url.pathname === '/v1/dispatch/lookup') {
        if (role !== 'dispatcher' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher role required' });
        }
        const b = await body();
        const out = await backend.lookup(b.code, b.responder_location, b.profile || 'foot');
        if (out.error) return json(res, out.http || 400, out);
        // occupant context is deliberately absent: consent-api resolves it
        // (C3). Absence here is the correct default, not an omission.
        out.occupant_context = { present: false };
        return json(res, 200, out);
      }

      if (req.method === 'POST' && url.pathname === '/v1/dispatch/assign') {
        if (role !== 'dispatcher' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher role required' });
        }
        const b = await body();
        const assigned = await backend.dispatch(b.code, b);
        if (assigned.error) return json(res, assigned.http || 400, assigned);
        return json(res, 200, assigned);
      }

      if (req.method === 'POST' && url.pathname === '/v1/dispatch/outcome') {
        if (role !== 'dispatcher' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher role required' });
        }
        const b = await body();
        const done = await backend.outcome(b.dispatch_id, b);
        if (done.error) return json(res, done.http || 400, done);
        return json(res, 200, done);
      }

      // ---- mapper worklist (two-speed, PRD 6.4) --------------------------
      if (req.method === 'GET' && url.pathname === '/v1/tasks') {
        return json(res, 200, {
          items: feedback.worklist({ assignee: url.searchParams.get('assignee') }),
        });
      }

      // ---- C8: the candidate worklist ------------------------------------
      if (req.method === 'GET' && url.pathname === '/v1/assertions/candidates') {
        return json(res, 200, {
          items: feedback.pendingCandidates({ type: url.searchParams.get('type') }),
        });
      }

      // ---- C8: the ONLY candidate -> ground-truth path --------------------
      if (req.method === 'POST' && /^\/v1\/assertions\/[^/]+\/verify$/.test(url.pathname)) {
        const id = url.pathname.split('/')[3];
        const b = await body();
        try {
          const out = feedback.verify({
            assertionId: id,
            outcome: b.outcome,
            value: b.value ?? null,
            // The verifying person is taken from the session, not the body:
            // a client must not be able to claim to be someone else.
            actor: req.headers['x-user'] || null,
            note: b.note ?? null,
          });
          return json(res, 200, out);
        } catch (e) {
          if (e.code === 'inference_cannot_verify') {
            return json(res, 403, { error: e.code, detail: e.message });
          }
          return json(res, 409, { error: 'verify_failed', detail: e.message });
        }
      }

      if (req.method === 'POST' && /^\/v1\/tasks\/[^/]+\/complete$/.test(url.pathname)) {
        const id = url.pathname.split('/')[3];
        const b = await body();
        try {
          return json(res, 200, feedback.completeTask({
            taskId: id, outcome: b.outcome ?? 'confirmed',
            actor: req.headers['x-user'] || null,
            note: b.note ?? null, updates: b.updates ?? null,
          }));
        } catch (e) {
          if (e.code === 'inference_cannot_verify') {
            return json(res, 403, { error: e.code, detail: e.message });
          }
          return json(res, 409, { error: 'complete_failed', detail: e.message });
        }
      }

      // ---- PRD 6.6 service-data disclosure --------------------------------
      if (req.method === 'GET' && /^\/v1\/zones\/[^/]+\/service-stats$/.test(url.pathname)) {
        const zone = url.pathname.split('/')[3];
        // Aggregate only. This is the ONLY service-data surface a public or
        // reporting consumer may reach (PRD 6.6).
        return json(res, 200, aggregateStats(registry, zone));
      }

      if (req.method === 'GET' && /^\/v1\/structures\/[^/]+\/services$/.test(url.pathname)) {
        const code = decodeURIComponent(url.pathname.split('/')[3]);
        try {
          const out = readServiceData({
            registry, role, code,
            opts: { municipalScopes: (req.headers['x-scopes'] ?? '').split(',').filter(Boolean) },
          });
          return json(res, 200, out);
        } catch (e) {
          if (e instanceof DisclosureRefused) {
            return json(res, e.http, { error: e.code, detail: e.message });
          }
          return json(res, e.http ?? 500, { error: 'service_read_failed', detail: e.message });
        }
      }

      // ---- Grievance (M7) ---------------------------------------------------
      if (req.method === 'POST' && url.pathname === '/v1/grievances') {
        const b = await body();
        // Rate limit: synthetic enforcement per device_hash (5/h, 20/d)
        const deviceHash = b.device_hash || 'unknown';
        const key = `griev:${deviceHash}`;
        // Synthetic rate-limit tracking (in-memory; production uses Redis)
        const nowTs = Date.now();
        const hourMs = 60 * 60 * 1000;
        const dayMs = 24 * hourMs;
        const recent = (global.__grievLimits?.get(key) || []).filter(
          ts => (nowTs - ts) < dayMs
        );
        const hourCount = recent.filter(ts => (nowTs - ts) < hourMs).length;
        if (hourCount >= 5) {
          return json(res, 429, { error: 'rate_limited', retry_after_sec: 3600 - Math.floor((nowTs - recent[0]) / 1000) });
        }
        if (recent.length >= 20) {
          return json(res, 429, { error: 'rate_limited', retry_after_sec: 86400 - Math.floor((nowTs - recent[0]) / 1000) });
        }
        recent.push(nowTs);
        if (!global.__grievLimits) global.__grievLimits = new Map();
        global.__grievLimits.set(key, recent);
        // Create grievance (synthetic test data only)
        const grievanceId = require('node:crypto').randomUUID();
        const reportedLocation = b.reported_location || { lat: 0, lon: 0 };
        const structureCode = b.structure_code || null;
        // Cross-check: >25m from registered structure -> dedup candidate, not direct assertion
        let offsetM = null;
        let crossCheckAction = 'asserted';
        let dedupCandidateId = null;
        if (structureCode) {
          const s = registry.getByCode(structureCode);
          if (!s) {
            return json(res, 404, { error: 'structure_not_found', code: structureCode });
          }
          const dx = (reportedLocation.lon - s.lon) * 111320 * Math.cos((reportedLocation.lat * Math.PI) / 180);
          const dy = (reportedLocation.lat - s.lat) * 110540;
          offsetM = Math.hypot(dx, dy);
          if (offsetM > 25) {
            crossCheckAction = 'dedup_candidate';
            // A report far from the registered location must not assert a
            // wrong structure: create a human-review dedup record instead.
            // The grievance has no second structure to pair with, so record
            // it as a verification event + open dedup queue entry is not
            // possible without a pair; instead open a mapper task flagged
            // for dedup review, linked to the grievance.
            dedupCandidateId = registry.enqueueTask({
              structure_id: s.id, zone: 'C4', kind: 'grievance_dedup_review',
              signal: 'fast', priority: 1,
              note: `Grievance report ${offsetM.toFixed(1)}m from ${structureCode}; possible wrong structure`,
              payload: { grievance_id: grievanceId, structure_code: structureCode, offset_m: offsetM, synthetic: true },
            });
          }
        }
        // Store grievance in SQLite (synthetic schema extension)
        registry.db.exec(`CREATE TABLE IF NOT EXISTS grievance (
          id TEXT PRIMARY KEY, structure_code TEXT, device_hash TEXT,
          reported_lat REAL, reported_lon REAL, offset_from_registered_m REAL,
          photo_sha256 TEXT, body TEXT, state TEXT DEFAULT 'received',
          weight REAL DEFAULT 0.1, source TEXT DEFAULT 'resident_report',
          created_at TEXT
        )`);
        registry.db.prepare(`
          INSERT INTO grievance (id, structure_code, device_hash, reported_lat,
            reported_lon, offset_from_registered_m, photo_sha256, body, state, weight, source, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).run(
          grievanceId, structureCode || null, deviceHash,
          reportedLocation.lat ?? null, reportedLocation.lon ?? null,
          offsetM, b.photo_sha256 || null, b.body || null,
          'received', 0.1, 'resident_report', new Date().toISOString()
        );
        // Weight assignment per M7 state machine docs
        const weight = (global.__grievWeights || { resident_report: 0.1, grievance_corroborated: 0.7, mapper_survey: 0.6, imagery_diff: 0.4, dispatch_feedback: 1.0 })['resident_report'] ?? 0.1;
        return json(res, 201, {
          grievance_id: grievanceId,
          state: 'received',
          weight, source: 'resident_report',
          cross_check_action: crossCheckAction,
          dedup_task_id: dedupCandidateId,
          offset_m: offsetM,
          synthetic: true,
        });
      }

      if (req.method === 'GET' && url.pathname === '/v1/grievances') {
        if (role !== 'dispatcher' && role !== 'reviewer' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher/reviewer/admin role required' });
        }
        const stateFilter = url.searchParams.get('state') || null;
        const zoneFilter = url.searchParams.get('zone') || null;
        let sql = 'SELECT * FROM grievance';
        const params = [];
        const conditions = [];
        if (stateFilter) { conditions.push('state = ?'); params.push(stateFilter); }
        if (zoneFilter) {
          const zone = registry.db.prepare('SELECT * FROM zone WHERE code = ?').get(zoneFilter);
          if (!zone || zone.lat == null || zone.radius_m == null) {
            return json(res, 200, { items: [], synthetic: true, note: 'Unknown zone.' });
          }
          const codes = new Set(
            registry.db.prepare('SELECT code, lat, lon FROM structure').all()
              .filter((s) => {
                const dx = (s.lon - zone.lon) * 111320 * Math.cos(zone.lat * Math.PI / 180);
                const dy = (s.lat - zone.lat) * 110540;
                return Math.hypot(dx, dy) <= zone.radius_m;
              }).map((s) => s.code));
          conditions.push('structure_code IN (' + [...codes].map(() => '?').join(',') + ')');
          if (!codes.size) conditions[conditions.length - 1] = '1 = 0';
          else params.push(...codes);
        }
        if (conditions.length) sql += ' WHERE ' + conditions.join(' AND ');
        const rows = registry.db.prepare(sql).all(...params);
        return json(res, 200, { items: rows, synthetic: true, note: 'Synthetic grievance data only; no real-world validation claimed.' });
      }

      if (req.method === 'POST' && /^\/v1\/grievances\/[^/]+\/triage$/.test(url.pathname)) {
        const grievanceId = url.pathname.split('/')[3];
        const b = await body();
        const row = registry.db.prepare('SELECT * FROM grievance WHERE id = ?').get(grievanceId);
        if (!row) return json(res, 404, { error: 'grievance_not_found', id: grievanceId });
        const targetState = b.state || 'corroborating';
        // State machine: received -> corroborating -> confirmed/rejected
        const allowedTransitions = {
          received: ['corroborating', 'rejected'],
          corroborating: ['confirmed', 'rejected', 'corroborating'],
          confirmed: ['rejected'],
          rejected: [],
        };
        const currentAllowed = allowedTransitions[row.state] || [];
        if (!currentAllowed.includes(targetState) && !(targetState === row.state)) {
          return json(res, 409, { error: 'invalid_state_transition', from: row.state, to: targetState, allowed: currentAllowed });
        }
        // Corroborated criteria: evidence weight >= 0.6 OR dispatch_feedback (1.0) OR combined >= 0.7
        let newWeight = row.weight;
        let newState = targetState;
        const weights = { resident_report: 0.1, grievance_corroborated: 0.7, mapper_survey: 0.6, imagery_diff: 0.4, dispatch_feedback: 1.0 };
        // Evidence source may be supplied on any transition; it determines
        // the weight used for the corroboration check below.
        newWeight = weights[b.source] ?? weights[b.evidence_class] ?? row.weight;
        if (targetState === 'confirmed') {
          // Confirmed requires weight >= 0.5 (per M7 design doc)
          if (newWeight < 0.5) {
            return json(res, 409, { error: 'corroboration_insufficient', weight: newWeight, minimum: 0.5 });
          }
        }
        registry.db.prepare('UPDATE grievance SET state = ?, weight = ? WHERE id = ?').run(targetState, newWeight, grievanceId);
        // Mapper task trigger on corroborating / confirmed (priority 1 fast signal)
        if (targetState === 'corroborating' || targetState === 'confirmed') {
          registry.enqueueTask({
            structure_id: row.structure_code ? registry.getByCode(row.structure_code)?.id ?? null : null,
            zone: 'C4', kind: 'grievance_review', signal: 'grievance',
            priority: 1, note: `Grievance ${grievanceId}: state=${targetState}`,
            payload: { grievance_id: grievanceId, synthetic: true }
          });
        }
        return json(res, 200, {
          grievance_id: grievanceId,
          state: targetState,
          weight: newWeight,
          transition_valid: true,
          synthetic: true,
          mapper_task_triggered: (targetState === 'corroborating' || targetState === 'confirmed'),
        });
      }

      // ---- C7 zone kill switch --------------------------------------------
      if (req.method === 'GET' && url.pathname === '/v1/zones') {
        return json(res, 200, {
          zones: registry.db.prepare('SELECT * FROM zone').all(),
        });
      }

      return json(res, 404, { error: 'not_found', path: url.pathname });
    } catch (e) {
      return json(res, 500, { error: 'internal', detail: e.message });
    }
  });

  srv.registry = registry;
  srv.backend = backend;
  return srv;
}

if (require.main === module) {
  createServer().listen(PORT, () => {
    console.log(`registry-api listening on :${PORT}`);
  });
}

module.exports = { createServer };