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
  router = process.env.GRAPH_URL ? null : null,
} = {}) {
  // PRD 3: the backend is configuration-selected, and the core depends only on
  // the interface. A future external adapter registers here unchanged.
  const backend = createBackend(backendName, { registry, router });

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
        return json(res, 200, await backend.dispatch(b.code, b));
      }

      if (req.method === 'POST' && url.pathname === '/v1/dispatch/outcome') {
        if (role !== 'dispatcher' && role !== 'admin') {
          return json(res, 403, { error: 'forbidden', detail: 'dispatcher role required' });
        }
        const b = await body();
        return json(res, 200, await backend.outcome(b.dispatch_id, b));
      }

      // ---- mapper worklist ------------------------------------------------
      if (req.method === 'GET' && url.pathname === '/v1/tasks') {
        return json(res, 200, { items: registry.openTasks() });
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