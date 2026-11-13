#!/usr/bin/env node
/**
 * Runs the whole PRD 6.8 loop against live services and fails loudly at the
 * first broken step. Used by `scripts/demo.sh selftest` before a demo.
 *
 *   REGISTRY=http://127.0.0.1:8090 node scripts/demo-selftest.js config/zones.campus.json
 *
 * Writes into whatever registry it is pointed at, so demo.sh runs it against a
 * throwaway in-memory instance, never the demo database.
 */

'use strict';

const fs = require('node:fs');

const REGISTRY = (process.env.REGISTRY || 'http://127.0.0.1:8090').replace(/\/$/, '');
const GRAPH = (process.env.GRAPH || 'http://127.0.0.1:8092').replace(/\/$/, '');
const zone = JSON.parse(fs.readFileSync(process.argv[2] || 'config/zones.campus.json', 'utf8'))
  .find((z) => z.dispatch_enabled);
if (!zone) throw new Error('no dispatch-enabled zone in the zones file');

const M_LAT = 110540;

async function call(base, path, { method = 'GET', body, token } = {}) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const out = await res.json().catch(() => ({}));
  return { status: res.status, out };
}

function step(name, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  — ${detail}` : ''}`);
  if (!ok) process.exit(1);
}

async function login(username, password) {
  const { status, out } = await call(REGISTRY, '/v1/auth/login', { method: 'POST', body: { username, password } });
  step(`login ${username}`, status === 200, status === 200 ? '' : JSON.stringify(out));
  return out.token;
}

(async () => {
  const mapper = await login('mapper', 'mapper123');

  // Three overlapping 120 m walks heading north from the zone centre, a few
  // metres apart and slightly noisy, like real repeated walks of one lane.
  const run = Date.now();
  let seq = 0;
  const ops = [];
  for (let t = 0; t < 3; t++) {
    const points = [];
    for (let i = 0; i < 60; i++) {
      points.push({
        seq: i,
        lat: zone.lat + (i * 2) / M_LAT,
        lon: zone.lon + (t - 1) * 0.00001 + Math.sin(i + t) * 0.000005,
      });
    }
    ops.push({ clientOpId: `selftest-${run}-walk-${t}`, clientSeq: ++seq, table: 'breadcrumb', op: 'create',
      payload: { trace_id: `selftest-${run}-${t}`, points } });
  }
  const dest = { lat: zone.lat + 100 / M_LAT, lon: zone.lon };

  // --seed: stand in for phone walks on a machine without GPS. Load the walks
  // into the running demo, build the graph, and leave the pin to the presenter.
  if (process.argv.includes('--seed')) {
    const seeded = await call(REGISTRY, '/v1/sync/push', { method: 'POST', token: mapper, body: { device_id: 'demo-seed', ops } });
    step('walks synced', seeded.status === 200 && seeded.out.results.every((r) => r.state === 'applied'));
    const built = await call(GRAPH, '/v1/graph/rebuild', { method: 'POST', body: { source: 'registry' } });
    step('graph rebuilt', built.status === 200, built.status === 200 ? `v${built.out.graph_version}` : JSON.stringify(built.out));
    console.log(`\nPin the demo structure at  lat ${dest.lat.toFixed(6)}  lon ${dest.lon.toFixed(6)}`);
    console.log(`Responder start (Settings): lat ${zone.lat}  lon ${zone.lon}`);
    return;
  }

  const dispatcher = await login('dispatcher', 'dispatch123');
  ops.push({ clientOpId: `selftest-${run}-pin`, clientSeq: ++seq, table: 'local_structure', op: 'create',
    payload: { centroid: dest, structure_type: 'standalone_dwelling',
      services: [{ service_type: 'water', source: 'shared_tap', supply_hours: [['06:00', '09:00']] }] } });

  const sync = await call(REGISTRY, '/v1/sync/push', { method: 'POST', token: mapper, body: { device_id: 'selftest', ops } });
  const pin = sync.out.results?.find((r) => r.clientOpId.endsWith('-pin'));
  step('mapper sync: walks + pin accepted', sync.status === 200 && sync.out.results.every((r) => r.state === 'applied'),
    JSON.stringify(sync.out.results?.map((r) => r.state)));
  step('structure got a code at sync', /^SLR-/.test(pin?.code ?? ''), pin?.code);

  const rebuild = await call(GRAPH, '/v1/graph/rebuild', { method: 'POST', body: { source: 'registry' } });
  step('graph rebuilt from breadcrumbs', rebuild.status === 200,
    rebuild.status === 200 ? `v${rebuild.out.graph_version}, ${rebuild.out.stats.edges} edges` : JSON.stringify(rebuild.out));

  const lookup = await call(REGISTRY, '/v1/dispatch/lookup', { method: 'POST', token: dispatcher,
    body: { code: pin.code, profile: 'foot', responder_location: { lat: zone.lat, lon: zone.lon } } });
  step('dispatcher lookup', lookup.status === 200, lookup.status === 200 ? '' : JSON.stringify(lookup.out));
  const route = lookup.out.route;
  step('route returned with map coordinates', route?.reachable === true && route.legs?.[0]?.from?.lat != null,
    route ? `${route.total_distance_m} m, ${route.legs.length} legs` : 'route: null (is GRAPH_URL set on the registry?)');

  const assign = await call(REGISTRY, '/v1/dispatch/assign', { method: 'POST', token: dispatcher,
    body: { code: pin.code, responder: 'unit-1' } });
  step('responder assigned', assign.status === 200, assign.out.dispatch_id);

  const outcome = await call(REGISTRY, '/v1/dispatch/outcome', { method: 'POST', token: dispatcher,
    body: { dispatch_id: assign.out.dispatch_id, outcome: 'failed' } });
  step('outcome "failed" recorded', outcome.status === 200);

  const tasks = await call(REGISTRY, '/v1/tasks', { token: mapper });
  const task = tasks.out.items?.find((t) => t.kind === 'dispatch_failure' && t.structure_id === pin.serverId);
  step('re-survey task opened for that structure', !!task, task ? `priority ${task.priority}` : '');

  console.log('\nLoop OK: map -> sync -> code -> lookup -> route -> failed -> re-survey task');
})().catch((e) => step('selftest crashed', false, e.message));
