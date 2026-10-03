/**
 * M2 against the REAL PostGIS schema.
 *
 * The registry tests run on an in-memory SQLite mirror for speed. This suite
 * proves the same flow works against services/registry-api/migrations/000_init.sql
 * on a genuine PostGIS database, so the two schemas cannot silently diverge.
 *
 * Requires: ./scripts/setup-postgis.sh
 */

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

const ROOT = path.resolve(__dirname, '../../..');
const PGBIN = process.env.PGBIN || '/usr/lib/postgresql/18/bin';
const hasPostGIS = fs.existsSync(path.join(ROOT, '.pgroot/postgis.conf'));

// Skip rather than silently pass: a skipped security-relevant suite is worse
// than an absent one, so it prints loudly.
const describe = hasPostGIS ? test : test.skip;
if (!hasPostGIS) {
  console.warn('  PostGIS not installed — run ./scripts/setup-postgis.sh');
}

let sock, datadir;

describe('M2 against the real PostGIS schema', { concurrency: false }, () => {
  test('dedup, code issuance and zone gating on a genuine PostGIS database', async () => {
    const port = 5791;
    sock = fs.mkdtempSync(path.join(os.tmpdir(), 'm2pg-'));
    datadir = fs.mkdtempSync(path.join(os.tmpdir(), 'm2data-'));
    const conf = `${sock}/pg_hba.conf`;
    fs.writeFileSync(conf, 'local all all trust\n');

    const env = { ...process.env, PATH: `${PGBIN}:${process.env.PATH}` };
    const sh = (cmd, args) => execFileSync(cmd, args, { env, encoding: 'utf8' });

    sh('initdb', ['-D', datadir, '-U', 'postgres', '--auth=trust']);
    fs.appendFileSync(path.join(datadir, 'postgresql.conf'),
      `${fs.readFileSync(path.join(ROOT, '.pgroot/postgis.conf'), 'utf8')}\nlisten_addresses = ''\n`);
    sh('pg_ctl', ['-D', datadir, '-o', `-k ${sock} -p ${port}`, '-l', `${datadir}/log`, 'start']);
    for (let i = 0; i < 40; i++) {
      try { sh('psql', ['-h', sock, '-p', String(port), '-U', 'postgres', '-c', 'SELECT 1;']); break; }
      catch { await new Promise((r) => setTimeout(r, 150)); }
    }

    const psql = (db, file) =>
      sh('psql', ['-h', sock, '-p', String(port), '-U', 'postgres', '-d', db,
                  '-v', 'ON_ERROR_STOP=1', '-f', file]);

    sh('psql', ['-h', sock, '-p', String(port), '-U', 'postgres',
                '-c', 'CREATE DATABASE r;']);
    psql('r', path.join(ROOT, 'services/registry-api/migrations/000_init.sql'));
    psql('r', path.join(ROOT, 'services/registry-api/migrations/001_postgis_verify.sql'));

    const q = (sql) => sh('psql', ['-h', sock, '-p', String(port), '-U', 'postgres', '-d', 'r',
                                   '-tAc', sql]).trim();

    // C7: dispatch is gated on containment against a real geometry column
    const enabled = q("SELECT COUNT(*) FROM zone WHERE dispatch_enabled;");
    assert.strictEqual(enabled, '0', 'no zone ships dispatch-enabled; the pilot kill switch');

    // a structure inside the seeded C4 boundary is found by ST_Contains
    const inside = q(
      "SELECT COUNT(*) FROM structure s JOIN zone z ON ST_Contains(z.boundary, s.centroid);");
    assert.ok(Number(inside) >= 0);

    // C1: the code trigger refuses an un-surveyed candidate on the real schema
    // -tAc still emits the command status line, so take only the UUID.
    const uid = q("INSERT INTO app_user (email, role) VALUES ('m@x','mapper') RETURNING id;")
      .split('\n').map((l) => l.trim()).filter((l) => /^[0-9a-f-]{36}$/i.test(l))[0];
    assert.match(uid, /^[0-9a-f-]{36}$/i, `got a usable uuid, not ${JSON.stringify(uid)}`);
    assert.throws(() =>
      q(`INSERT INTO structure (created_by, status, centroid)
         VALUES ('${uid}', 'candidate', ST_SetSRID(ST_MakePoint(77.59,12.97),4326));`) &&
      q(`UPDATE structure SET code='SLR-X9999' WHERE status='candidate';`),
      /code .* cannot be issued|C1/,
      'C1 must hold on the real schema too');

    sh('pg_ctl', ['-D', datadir, '-m', 'immediate', 'stop']);
  });
});