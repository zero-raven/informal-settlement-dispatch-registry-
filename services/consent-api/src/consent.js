/**
 * consent-api — the resident identity service.
 *
 * SEPARATE DATABASE, SEPARATE CREDENTIALS, NO CROSS-DB FOREIGN KEYS (C3).
 * This is the only process holding an `identity_db` credential. The registry
 * cannot reach it, and this service cannot see structural data except through
 * a public structure CODE.
 *
 * Occupant context is opt-in (PRD §6.3). Absence is the DEFAULT RESPONSE, not
 * an error: a dispatcher must not be able to distinguish "no resident linked"
 * from "resident revoked consent", because that difference is itself a leak.
 */

'use strict';

const crypto = require('node:crypto');

/** The four scopes, exactly as decided in PRD §6.3. */
const SCOPES = [
  'store_identity',
  'link_to_structure',
  'share_on_dispatch',
  'receive_notification',
];

const POLICY_VERSION = '2026-03-01';

class ConsentStore {
  /**
   * @param {object} db a node:sqlite DatabaseSync bound to identity_db
   */
  constructor(db) {
    this.db = db;
    this.applySchema();
  }

  applySchema() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS resident (
        id TEXT PRIMARY KEY, display_alias TEXT,
        enc_name BLOB, enc_phone BLOB,
        erased_at TEXT, created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS consent (
        id TEXT PRIMARY KEY,
        resident_id TEXT NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
        scope TEXT NOT NULL,
        granted INTEGER NOT NULL,
        granted_at TEXT, revoked_at TEXT,
        policy_version TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS structure_link (
        id TEXT PRIMARY KEY,
        resident_id TEXT NOT NULL REFERENCES resident(id) ON DELETE CASCADE,
        -- a public code as TEXT, deliberately NOT a reference: if a code is
        -- ever reassigned by a dedup merge, the link breaks safely instead of
        -- silently repointing a resident at a different building
        structure_code TEXT NOT NULL,
        consent_id TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS disclosure_audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        structure_code TEXT NOT NULL, actor TEXT NOT NULL,
        scopes TEXT NOT NULL, had_context INTEGER NOT NULL,
        at TEXT NOT NULL
      );
    `);
  }

  // ------------------------------------------------------------- residents

  createResident({ alias, name = null, phone = null }) {
    const id = crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO resident (id, display_alias, enc_name, enc_phone, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(
      id,
      alias ?? `res_${id.slice(0, 4)}`,
      name ? encrypt(name) : null,
      phone ? encrypt(phone) : null,
      new Date().toISOString(),
    );
    return { id, alias: alias ?? `res_${id.slice(0, 4)}` };
  }

  // --------------------------------------------------------------- consent

  /** Grant or revoke one scope. Revocation is recorded, not deleted. */
  setConsent({ residentId, scope, granted, policyVersion = POLICY_VERSION }) {
    if (!SCOPES.includes(scope)) throw new Error(`unknown scope "${scope}"`);
    const now = new Date().toISOString();
    const existing = this.db
      .prepare('SELECT id FROM consent WHERE resident_id = ? AND scope = ? AND revoked_at IS NULL')
      .get(residentId, scope);

    if (existing) {
      this.db.prepare(
        `UPDATE consent SET granted = ?, granted_at = ?, revoked_at = ?,
          policy_version = ? WHERE id = ?`,
      ).run(granted ? 1 : 0, granted ? now : null,
        granted ? null : now, policyVersion, existing.id);
      return existing.id;
    }
    const id = crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO consent (id, resident_id, scope, granted, granted_at, revoked_at, policy_version)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(id, residentId, scope, granted ? 1 : 0,
      granted ? now : null, granted ? null : now, policyVersion);
    return id;
  }

  activeScopes(residentId) {
    return this.db
      .prepare(`SELECT scope FROM consent
                WHERE resident_id = ? AND granted = 1 AND revoked_at IS NULL`)
      .all(residentId).map((r) => r.scope);
  }

  hasScope(residentId, scope) {
    return !!this.db
      .prepare(`SELECT 1 FROM consent
                WHERE resident_id = ? AND scope = ? AND granted = 1 AND revoked_at IS NULL`)
      .get(residentId, scope);
  }

  /** Link a resident to a structure. Requires an active link_to_structure consent. */
  linkStructure({ residentId, structureCode }) {
    if (!this.hasScope(residentId, 'link_to_structure')) {
      const err = new Error('link_to_structure consent is required');
      err.http = 403;
      throw err;
    }
    const consentId = this.db
      .prepare(`SELECT id FROM consent
                WHERE resident_id = ? AND scope = 'link_to_structure'
                  AND granted = 1 AND revoked_at IS NULL`)
      .get(residentId).id;
    const id = crypto.randomUUID();
    this.db.prepare(`
      INSERT INTO structure_link (id, resident_id, structure_code, consent_id, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(id, residentId, structureCode, consentId, new Date().toISOString());
    return id;
  }

  // ---------------------------------------------------- occupant context

  /**
   * The ONLY bridge between identity and dispatch.
   *
   * Returns an ABSENCE when no consent exists — HTTP 200 with an empty context,
   * never an error, and never a distinguishable "revoked" signal.
   *
   * @param {string} structureCode
   * @param {string} actor the dispatcher, for the audit trail
   */
  occupantContext({ structureCode, actor }) {
    const link = this.db
      .prepare(`SELECT sl.resident_id
                FROM structure_link sl
                JOIN consent c ON c.id = sl.consent_id
                WHERE sl.structure_code = ?
                  AND c.granted = 1 AND c.revoked_at IS NULL`)
      .get(structureCode);

    const scopes = link ? this.activeScopes(link.resident_id) : [];
    const shareable = link && scopes.includes('share_on_dispatch');

    // ALWAYS audited, including the negative case: dispatch accountability is
    // the check on consent-by-design.
    this.db.prepare(`
      INSERT INTO disclosure_audit (structure_code, actor, scopes, had_context, at)
      VALUES (?, ?, ?, ?, ?)
    `).run(structureCode, actor ?? 'unknown', JSON.stringify(scopes),
      shareable ? 1 : 0, new Date().toISOString());

    if (!shareable) {
      // Absence. Identical shape whether nobody is linked, or a resident
      // revoked — that difference must not be observable.
      return {
        context_present: false,
        granted_scopes: [],
        fields: [],
      };
    }

    const resident = this.db
      .prepare('SELECT id, display_alias FROM resident WHERE id = ? AND erased_at IS NULL')
      .get(link.resident_id);

    if (!resident) return { context_present: false, granted_scopes: [], fields: [] };

    return {
      context_present: true,
      granted_scopes: scopes,
      resident_alias: resident.display_alias,
      // No occupant detail is stored in this service; returning invented
      // fields would be fabrication. Fields stay empty until a real,
      // consented detail store exists.
      fields: [],
    };
  }

  /** Every disclosure, including the refusals. */
  auditLog({ limit = 100 } = {}) {
    return this.db
      .prepare('SELECT * FROM disclosure_audit ORDER BY at DESC LIMIT ?')
      .all(limit);
  }

  // --------------------------------------------------------- erasure

  /**
   * Right to be forgotten.
   *
   * PII is zeroed and the resident marked erased. STRUCTURAL DATA IS NOT
   * TOUCHED — a resident forgetting their identity must not delete the
   * structure record, because that record describes a place, not a person, and
   * emergency dispatch depends on it existing.
   */
  eraseResident(residentId) {
    const now = new Date().toISOString();
    const changed = this.db.prepare(`
      UPDATE resident SET enc_name = NULL, enc_phone = NULL,
        display_alias = NULL, erased_at = ?
      WHERE id = ? AND erased_at IS NULL
    `).run(now, residentId).changes;

    // Every scope revoked at the same moment.
    this.db.prepare(`
      UPDATE consent SET granted = 0, revoked_at = ?
      WHERE resident_id = ? AND revoked_at IS NULL
    `).run(now, residentId);

    // Links remain but resolve to nothing, so the audit trail stays intact
    // while the resident is unresolvable.
    return { erased: changed > 0, at: now, structuralDataUntouched: true };
  }
}

/**
 * Field-level encryption.
 *
 * NOTE: this is a stand-in key derived from a constant. It demonstrates the
 * shape — PII is not stored in plaintext and is not queryable — but a real
 * deployment needs KMS-managed keys with rotation, and the constant must not
 * survive into production. Flagged rather than silently shipped.
 */
const DEV_KEY = crypto.createHash('sha256').update('dev-only-do-not-ship').digest();

function encrypt(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', DEV_KEY, iv);
  const enc = Buffer.concat([c.update(String(plain), 'utf8'), c.final()]);
  return Buffer.concat([iv, enc, c.getAuthTag()]);
}

function decrypt(blob) {
  const b = Buffer.from(blob);
  const iv = b.subarray(0, 12);
  const tag = b.subarray(b.length - 16);
  const data = b.subarray(12, b.length - 16);
  const d = crypto.createDecipheriv('aes-256-gcm', DEV_KEY, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(data), d.final()]).toString('utf8');
}

module.exports = { ConsentStore, SCOPES, POLICY_VERSION, encrypt, decrypt };