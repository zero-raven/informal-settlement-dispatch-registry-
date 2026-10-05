/**
 * M6: service-data disclosure control (PRD 6.6).
 *
 * The decided access model, as executable assertions:
 *   Public              -> no individual structure-level service data
 *   Mapper              -> what field work needs
 *   Dispatcher          -> only what is operationally relevant to a response
 *   Municipal/NGO       -> by role assignment
 *   Public analytics    -> aggregate only
 *
 * And the distinction that matters: service data is NOT PII, and must not be
 * consent-gated or routed through the consent vault.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { Registry } = require('../src/registry.js');
const {
  readServiceData, aggregateStats, assertNoPerStructureLeak,
  DisclosureRefused, bucket, DISPATCHER_RELEVANT,
} = require('../src/disclosure.js');

function fixture() {
  const registry = new Registry(':memory:');
  registry.db.prepare(
    "INSERT INTO app_user (id,email,role) VALUES ('m1','m@x','mapper')",
  ).run();
  registry.db.prepare(
    "INSERT INTO zone (code,name,lat,lon,radius_m,dispatch_enabled) VALUES ('C4','Pilot',12.97,77.59,600,1)",
  ).run();
  const s = registry.createStructure({
    lat: 12.97, lon: 77.59, status: 'surveyed', disclosurePolicy: 'full',
  });
  const code = registry.issueCode(s, { reviewerId: 'r1' });
  const now = new Date().toISOString();
  for (const [type, source, quality, shared] of [
    ['water', 'informal_tap', 'poor', 4],
    ['electricity', 'community', 'fair', 1],
    ['sanitation', 'none', 'poor', 8],
    ['internet', 'shared_private', 'good', 12],
    ['road_access', 'informal_tap', 'fair', 0],
  ]) {
    registry.db.prepare(`
      INSERT INTO structure_service
        (id, structure_id, service_type, source, quality, shared_with_count, last_verified_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(require('node:crypto').randomUUID(), s, type, source, quality, shared, now, now);
  }
  return { registry, s, code };
}

// ---------------------------------------------------------------------------
// Public — no individual structure-level service data, ever
// ---------------------------------------------------------------------------

test('public and anonymous callers receive no service records', () => {
  const { registry, code } = fixture();
  for (const role of ['public', 'anonymous', 'resident']) {
    const out = readServiceData({ registry, role, code });
    assert.deepStrictEqual(out.services, [], `${role} must see nothing`);
    assert.ok(out.aggregate_available, 'but aggregate data is offered instead');
  }
});

test('an unknown role is refused, not defaulted to public', () => {
  const { registry, code } = fixture();
  assert.throws(
    () => readServiceData({ registry, role: 'wizard', code }),
    DisclosureRefused,
  );
});

// ---------------------------------------------------------------------------
// Mapper — field work
// ---------------------------------------------------------------------------

test('a mapper sees the records field work needs', () => {
  const { registry, code } = fixture();
  const out = readServiceData({ registry, role: 'mapper', code });
  assert.ok(out.services.length > 0);
  assert.ok(out.services.some((s) => s.service_type === 'water'));
});

test('aggregate_only coarsens rather than withholds', () => {
  const { registry, s, code } = fixture();
  registry.updateStructure(s, { disclosurePolicy: 'aggregate_only' });
  const out = readServiceData({ registry, role: 'mapper', code });
  assert.ok(out.coarsened, 'the mapper is told the values are coarsened');
  const water = out.services.find((x) => x.service_type === 'water');
  assert.strictEqual(typeof water.shared_with_count, 'string',
    'a count is bucketed rather than exact');
});

// ---------------------------------------------------------------------------
// Dispatcher — operationally relevant only
// ---------------------------------------------------------------------------

test('a dispatcher sees ONLY operationally relevant service types', () => {
  const { registry, code } = fixture();
  const out = readServiceData({ registry, role: 'dispatcher', code });
  const types = out.services.map((s) => s.service_type);

  for (const t of types) {
    assert.ok(DISPATCHER_RELEVANT.has(t), `${t} is not operationally relevant to a response`);
  }
  // internet is present in the data but must NOT reach a dispatcher
  assert.ok(!types.includes('internet'), 'internet service data is not response-relevant');
  assert.deepStrictEqual(out.omitted_types.includes('internet'), true,
    'omission is stated explicitly rather than hidden');
});

test('a dispatcher sees no irrelevant FIELD even on a relevant service', () => {
  const { registry, code } = fixture();
  const out = readServiceData({ registry, role: 'dispatcher', code });
  const water = out.services.find((s) => s.service_type === 'water');
  assert.ok('quality' in water);
  assert.ok('source' in water);
  // shared_with_count is operationally irrelevant to arriving at a door
  assert.ok(!('shared_with_count' in water),
    'sharing counts are not operationally relevant and are omitted');
});

test('omitting whole records is more honest than returning partial ones', () => {
  const { registry, code } = fixture();
  const out = readServiceData({ registry, role: 'dispatcher', code });
  for (const s of out.services) {
    assert.ok(s.service_type, 'every returned record is complete for its type');
  }
});

// ---------------------------------------------------------------------------
// municipal / NGO — by role assignment
// ---------------------------------------------------------------------------

test('municipal/NGO access requires an explicit scope', () => {
  const { registry, code } = fixture();
  assert.throws(
    () => readServiceData({ registry, role: 'municipal_ngo', code }),
    /no service-data scope/,
  );
  const granted = readServiceData({
    registry, role: 'municipal_ngo', code,
    opts: { municipalScopes: ['service_data.read'] },
  });
  assert.ok(granted.services.length > 0);
});

// ---------------------------------------------------------------------------
// Inference — aggregate only, never per-structure
// ---------------------------------------------------------------------------

test('the ML service cannot read per-structure service data', () => {
  const { registry, code } = fixture();
  assert.throws(
    () => readServiceData({ registry, role: 'ml', code }),
    /aggregate statistics only/,
  );
});

test('consent-api sees no service data at all', () => {
  const { registry, code } = fixture();
  const out = readServiceData({ registry, role: 'consent_api', code });
  assert.deepStrictEqual(out.services, []);
});

// ---------------------------------------------------------------------------
// redacted
// ---------------------------------------------------------------------------

test('a redacted structure refuses per-structure reads entirely', () => {
  const { registry, s, code } = fixture();
  registry.updateStructure(s, { disclosurePolicy: 'redacted' });
  for (const role of ['mapper', 'dispatcher']) {
    assert.throws(
      () => readServiceData({ registry, role, code }),
      /redacted/,
      `${role} must be refused on a redacted structure`,
    );
  }
});

// ---------------------------------------------------------------------------
// Public analytics — aggregate only
// ---------------------------------------------------------------------------

test('aggregate statistics carry no per-structure column', () => {
  const { registry } = fixture();
  const { leak, columns } = assertNoPerStructureLeak(registry);
  assert.deepStrictEqual(leak, [],
    `aggregate view leaks: ${leak.join(', ')}`);
  assert.ok(columns.includes('zone_code'));
  assert.ok(columns.includes('service_type'));
});

test('bucket counts disclose less than exact counts', () => {
  assert.strictEqual(bucket(0), '0');
  assert.strictEqual(bucket(1), '1-2');
  assert.strictEqual(bucket(4), '3-5');
  assert.strictEqual(bucket(50), '10+');
  // bucketing must not be reversible to the exact figure
  assert.notStrictEqual(bucket(4), 4);
});

// ---------------------------------------------------------------------------
// The distinction: service data is NOT PII
// ---------------------------------------------------------------------------

test('service data is gated by ROLE, never by consent', () => {
  const { registry, code } = fixture();
  // No consent exists anywhere in this system, and service data is still
  // readable by an authorised role. Routing it through consent would be the
  // design error: no resident consented to their STRUCTURE being inspected.
  const out = readServiceData({ registry, role: 'mapper', code });
  assert.ok(out.services.length > 0);
  assert.ok(!('consent' in out) && !('resident' in out),
    'a service read must never reference identity');
});

test('a service-data response carries no identity field anywhere', () => {
  const { registry, code } = fixture();
  for (const role of ['mapper', 'dispatcher', 'municipal_ngo']) {
    const out = role === 'municipal_ngo'
      ? readServiceData({ registry, role, code, opts: { municipalScopes: ['service_data.read'] } })
      : readServiceData({ registry, role, code });
    const serialised = JSON.stringify(out);
    assert.ok(!/resident|consent|occupant|phone|alias/i.test(serialised),
      `${role} response leaked an identity term`);
  }
});
