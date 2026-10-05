/**
 * M6: consent vault and the occupant-context bridge (PRD 6.3, C3).
 *
 * The load-bearing property: a dispatcher must NOT be able to distinguish
 * "no resident linked" from "resident revoked consent". If they can, that
 * difference is itself a disclosure.
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { DatabaseSync } = require('node:sqlite');
const { ConsentStore, SCOPES, encrypt, decrypt } = require('../src/consent.js');

function store() {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys = ON');
  return new ConsentStore(db);
}

test('a new resident has no consent for anything', () => {
  const c = store();
  const r = c.createResident({ alias: 'res-1' });
  assert.deepStrictEqual(c.activeScopes(r.id), []);
  assert.strictEqual(r.alias, 'res-1');
});

test('only the four documented scopes are grantable', () => {
  const c = store();
  const r = c.createResident({});
  for (const s of SCOPES) c.setConsent({ residentId: r.id, scope: s, granted: true });
  assert.deepStrictEqual(c.activeScopes(r.id).sort(), [...SCOPES].sort());
  assert.throws(
    () => c.setConsent({ residentId: r.id, scope: 'read_my_mind', granted: true }),
    /unknown scope/,
  );
});

test('linking a structure requires link_to_structure consent', () => {
  const c = store();
  const r = c.createResident({});
  assert.throws(
    () => c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' }),
    /consent is required/,
  );
  c.setConsent({ residentId: r.id, scope: 'link_to_structure', granted: true });
  assert.ok(c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' }));
});

test('revocation is recorded, not deleted', () => {
  const c = store();
  const r = c.createResident({});
  c.setConsent({ residentId: r.id, scope: 'store_identity', granted: true });
  c.setConsent({ residentId: r.id, scope: 'store_identity', granted: false });
  assert.deepStrictEqual(c.activeScopes(r.id), []);
  const rows = c.db.prepare('SELECT * FROM consent WHERE scope = ?').all('store_identity');
  assert.ok(rows.length >= 1);
  assert.ok(rows.some((x) => x.revoked_at));
});

test('no link at all returns an absence, not an error', () => {
  const c = store();
  const out = c.occupantContext({ structureCode: 'SLR-C41001', actor: 'dispatch:u1' });
  assert.strictEqual(out.context_present, false);
  assert.deepStrictEqual(out.granted_scopes, []);
  assert.deepStrictEqual(out.fields, []);
});

test('linked but share_on_dispatch NOT granted returns the same absence shape', () => {
  const c = store();
  const r = c.createResident({});
  c.setConsent({ residentId: r.id, scope: 'link_to_structure', granted: true });
  c.setConsent({ residentId: r.id, scope: 'store_identity', granted: true });
  c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' });

  const out = c.occupantContext({ structureCode: 'SLR-C41001', actor: 'dispatch:u1' });
  assert.strictEqual(out.context_present, false);
});

test('revocation produces a response IDENTICAL to never-linked', () => {
  const c = store();
  const a = c.createResident({});
  c.setConsent({ residentId: a.id, scope: 'link_to_structure', granted: true });
  c.setConsent({ residentId: a.id, scope: 'share_on_dispatch', granted: true });
  c.linkStructure({ residentId: a.id, structureCode: 'SLR-C41002' });
  const before = c.occupantContext({ structureCode: 'SLR-C41002', actor: 'd' });
  assert.strictEqual(before.context_present, true);

  c.setConsent({ residentId: a.id, scope: 'share_on_dispatch', granted: false });
  const afterRevoked = c.occupantContext({ structureCode: 'SLR-C41002', actor: 'd' });
  const never = c.occupantContext({ structureCode: 'SLR-C99999', actor: 'd' });

  assert.deepStrictEqual(afterRevoked, never,
    'revoked must be indistinguishable from never-linked');
});

test('full consent returns the context', () => {
  const c = store();
  const r = c.createResident({ alias: 'res-7f2a' });
  c.setConsent({ residentId: r.id, scope: 'link_to_structure', granted: true });
  c.setConsent({ residentId: r.id, scope: 'share_on_dispatch', granted: true });
  c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' });

  const out = c.occupantContext({ structureCode: 'SLR-C41001', actor: 'dispatch:u7' });
  assert.strictEqual(out.context_present, true);
  assert.strictEqual(out.resident_alias, 'res-7f2a');
  assert.ok(out.granted_scopes.includes('share_on_dispatch'));
  assert.ok(out.fields.length > 0);
});

test('every disclosure is audited, including the refusals', () => {
  const c = store();
  const r = c.createResident({});
  c.setConsent({ residentId: r.id, scope: 'link_to_structure', granted: true });
  c.setConsent({ residentId: r.id, scope: 'share_on_dispatch', granted: true });
  c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' });

  c.occupantContext({ structureCode: 'SLR-C41001', actor: 'dispatch:u1' });
  c.occupantContext({ structureCode: 'SLR-C99999', actor: 'dispatch:u2' });

  const log = c.auditLog();
  assert.strictEqual(log.length, 2, 'the refusal is audited too');
  assert.ok(log.some((l) => l.had_context === 1));
  assert.ok(log.some((l) => l.had_context === 0));
  assert.ok(log.every((l) => l.actor.startsWith('dispatch:')));
});

test('erasure zeroes PII and leaves structural data untouched', () => {
  const c = store();
  const r = c.createResident({ alias: 'res-1', name: 'Real Name', phone: '+91...' });
  c.setConsent({ residentId: r.id, scope: 'link_to_structure', granted: true });
  c.setConsent({ residentId: r.id, scope: 'share_on_dispatch', granted: true });
  c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' });

  const out = c.eraseResident(r.id);
  assert.strictEqual(out.erased, true);
  assert.strictEqual(out.structuralDataUntouched, true);

  const row = c.db.prepare('SELECT * FROM resident WHERE id = ?').get(r.id);
  assert.strictEqual(row.enc_name, null);
  assert.strictEqual(row.enc_phone, null);
  assert.ok(row.erased_at);

  assert.deepStrictEqual(c.activeScopes(r.id), []);
  assert.strictEqual(
    c.occupantContext({ structureCode: 'SLR-C41001', actor: 'd' }).context_present, false);
});

test('PII is not stored in plaintext', () => {
  const c = store();
  const r = c.createResident({ name: 'SENSITIVE NAME', phone: '+919999999999' });
  const row = c.db.prepare('SELECT * FROM resident WHERE id = ?').get(r.id);
  const blob = Buffer.from(row.enc_name).toString('binary');
  assert.ok(!blob.includes('SENSITIVE'));
  assert.strictEqual(decrypt(row.enc_name), 'SENSITIVE NAME');
});

test('structure_link holds a public code, not a structural row reference', () => {
  const c = store();
  const r = c.createResident({});
  c.setConsent({ residentId: r.id, scope: 'link_to_structure', granted: true });
  c.linkStructure({ residentId: r.id, structureCode: 'SLR-C41001' });

  const cols = c.db.prepare('PRAGMA table_info(structure_link)').all().map((x) => x.name);
  assert.ok(cols.includes('structure_code'));
  assert.ok(!cols.some((x) => /structure_id|foreign/i.test(x)),
    'no structural reference may exist in the identity database');
});
